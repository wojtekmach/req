# Experimental httpc adapter to test the adapter contract.

defmodule Req.HTTPC do
  def run(request) do
    case prepare_body(request) do
      {:halt, request} ->
        {request, Req.Response.new(status: nil, body: "")}

      {request, body} ->
        run(request, body)
    end
  end

  defp run(request, body) do
    {profile, request, httpc_http_options, httpc_options} = prepare_request(request)
    httpc_url = request.url |> URI.to_string() |> String.to_charlist()

    httpc_headers =
      for {name, values} <- request.headers,
          # TODO: remove List.wrap on Req 1.0
          value <- List.wrap(values) do
        {String.to_charlist(name), String.to_charlist(value)}
      end

    httpc_req =
      if request.method in [:post, :put] do
        content_type =
          case Req.Request.get_header(request, "content-type") do
            [value] ->
              String.to_charlist(value)

            [] ->
              ~c"application/octet-stream"
          end

        {httpc_url, httpc_headers, content_type, body}
      else
        {httpc_url, httpc_headers}
      end

    case request.into do
      nil ->
        httpc_stream(request, httpc_req, httpc_http_options, httpc_options, profile)

      :self ->
        httpc_stream_into_self(request, httpc_req, httpc_http_options, httpc_options, profile)
    end
  end

  defp prepare_body(request) do
    case request.body do
      nil ->
        {request, ""}

      iodata when is_binary(iodata) or is_list(iodata) ->
        {request, iodata}

      fun when is_function(fun, 1) ->
        drain_req_body_fun(fun, request, [])

      %Req.Response.Async{} = async ->
        # Async's Enumerable reads response chunks from this (the caller's) process
        # mailbox, so it must be consumed here rather than driven from httpc's process.
        {request, Enum.to_list(async)}

      {:stream, enumerable} ->
        {request, stream_body(request, enumerable)}

      enumerable ->
        {request, stream_body(request, enumerable)}
    end
  end

  # Stream the body lazily, framing it the same way the finch and mint adapters do:
  # when Req has computed the size (content-length is set) send it with that length
  # (plain generator), otherwise use chunked transfer-encoding (`:chunkify`).
  defp stream_body(request, enumerable) do
    reducer = fn element, _acc -> {:suspend, {:elem, element}} end
    start = fn command -> Enumerable.reduce(enumerable, command, reducer) end

    case Req.Request.get_header(request, "content-length") do
      [] -> {:chunkify, &next_chunk/1, start}
      _ -> {&next_chunk/1, start}
    end
  end

  # Resume the suspended reduction and emit one element, carrying the next
  # continuation. Elements are wrapped in `{:elem, _}` so a combinator like
  # `Stream.take` that halts on the same step it yields its last element (returning
  # `{:halted, {:elem, _}}`) is distinguishable from a halt with nothing pending.
  # Empty elements are skipped because httpc encodes a zero-length chunk as the
  # "0\r\n\r\n" body terminator, which would end a chunked request body early.
  defp next_chunk(continuation) do
    case continuation.({:cont, :none}) do
      {:suspended, {:elem, element}, next} ->
        emit_chunk(element, next)

      {:halted, {:elem, element}} ->
        emit_chunk(element, fn _command -> {:halted, :none} end)

      {:halted, :none} ->
        :eof

      {:done, _acc} ->
        :eof
    end
  end

  defp emit_chunk(element, next) do
    if IO.iodata_length(element) == 0 do
      next_chunk(next)
    else
      {:ok, element, next}
    end
  end

  defp drain_req_body_fun(fun, request, acc) do
    case fun.(request) do
      {:data, chunk, request} ->
        drain_req_body_fun(fun, request, [acc | chunk])

      {:done, request} ->
        {request, acc}

      {:halt, request} ->
        {:halt, request}

      other ->
        raise "expected req_body_fun to return {:data, chunk, request}, {:done, request}, or {:halt, request}, got: #{inspect(other)}"
    end
  end

  defp prepare_request(request) do
    httpc_http_options = [
      autoredirect: false,
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        depth: 2,
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ]
      ]
    ]

    httpc_options = [
      body_format: :binary
    ]

    httpc_http_options =
      if timeout = request.options[:request_timeout] || request.options[:receive_timeout] do
        Keyword.put(httpc_http_options, :timeout, timeout)
      else
        httpc_http_options
      end

    connect_options = request.options[:connect_options] || []

    {httpc_http_options, httpc_options} =
      httpc_connect_options(request, connect_options, httpc_http_options, httpc_options)

    httpc_options =
      if request.url.host && String.contains?(request.url.host, ":") do
        Keyword.put(httpc_options, :ipv6_host_with_brackets, true)
      else
        httpc_options
      end

    profile_options =
      if request.options[:inet6] == true or String.contains?(request.url.host || "", ":") do
        [ipfamily: :inet6fb4]
      else
        []
      end

    profile_options =
      if unix_socket = request.options[:unix_socket] do
        profile_options
        |> Keyword.put(:ipfamily, :local)
        |> Keyword.put(:unix_socket, to_charlist(unix_socket))
      else
        profile_options
      end

    {profile, request} =
      if profile_options == [] do
        {:default, request}
      else
        profile = :"#{__MODULE__}.#{System.unique_integer([:positive])}"
        {:ok, pid} = :inets.start(:httpc, [profile: profile], :stand_alone)
        Process.link(pid)
        :ok = :httpc.set_options(profile_options, pid)
        {pid, request}
      end

    {profile, request, httpc_http_options, httpc_options}
  end

  defp httpc_connect_options(_request, [], httpc_http_options, httpc_options) do
    {httpc_http_options, httpc_options}
  end

  defp httpc_connect_options(request, connect_options, httpc_http_options, httpc_options) do
    httpc_http_options =
      if timeout = connect_options[:timeout] do
        Keyword.put(httpc_http_options, :connect_timeout, timeout)
      else
        httpc_http_options
      end

    {ssl_opts, socket_opts} =
      Keyword.split(connect_options[:transport_opts] || [], [:cacertfile, :certfile, :keyfile])

    httpc_options =
      if socket_opts != [] do
        Keyword.put(httpc_options, :socket_opts, socket_opts)
      else
        httpc_options
      end

    httpc_http_options =
      if ssl_opts != [] and request.url.scheme == "https" do
        if cacertfile = ssl_opts[:cacertfile], do: File.read!(cacertfile)

        Keyword.update!(httpc_http_options, :ssl, fn ssl ->
          ssl
          |> Keyword.delete(:cacerts)
          |> Keyword.merge(ssl_opts)
          |> Keyword.replace_lazy(:cacertfile, &String.to_charlist/1)
        end)
      else
        httpc_http_options
      end

    {httpc_http_options, httpc_options}
  end

  defp normalize_error(:timeout) do
    %Req.TransportError{reason: :timeout}
  end

  defp normalize_error({:failed_connect, _} = reason) do
    %Req.TransportError{reason: transport_error_reason(reason)}
  end

  defp normalize_error({:could_not_parse_as_http, _}) do
    %Req.HTTPError{protocol: :http1, reason: :invalid_status_line}
  end

  defp transport_error_reason({:failed_connect, [{:to_address, _}, {_family, _opts, reason}]}) do
    reason
  end

  defp transport_error_reason(
         {:failed_connect,
          [{:to_address, _}, {_family1, _opts1, _reason1}, {_family2, _opts2, reason2}]}
       ) do
    reason2
  end

  defp start_request(request, httpc_req, httpc_http_options, httpc_options, profile) do
    caller = self()
    receiver = &httpc_receiver(&1, caller)
    httpc_options = [sync: false, stream: :self, receiver: receiver] ++ httpc_options

    {:ok, ref} =
      :httpc.request(request.method, httpc_req, httpc_http_options, httpc_options, profile)

    ref
  end

  defp httpc_stream(request, httpc_req, httpc_http_options, httpc_options, profile) do
    ref = start_request(request, httpc_req, httpc_http_options, httpc_options, profile)

    case recv_status_and_headers(request, ref) do
      {:ok, resp} ->
        httpc_stream_loop(request, request.stream, resp, ref, request.private[:req_stream_acc])

      {:error, request, exception} ->
        {request, exception}
    end
  end

  defp httpc_stream_into_self(request, httpc_req, httpc_http_options, httpc_options, profile) do
    ref = start_request(request, httpc_req, httpc_http_options, httpc_options, profile)

    case recv_status_and_headers(request, ref) do
      {:ok, resp} ->
        async = %Req.Response.Async{
          pid: self(),
          ref: ref,
          stream_fun: &httpc_parse_message/2,
          cancel_fun: &httpc_cancel/1
        }

        resp = %{resp | body: async}

        case request.stream.(:eof, resp, request.private[:req_stream_acc]) do
          {:ok, resp, _acc} ->
            {request, resp}

          {:error, resp, exception, acc} ->
            {Req.Request.put_private(resp.request, :req_stream_acc, acc), exception}
        end

      {:error, request, exception} ->
        {request, exception}
    end
  end

  defp recv_status_and_headers(request, ref) do
    receive do
      {^ref, {:status, status}} ->
        receive do
          {^ref, {:headers, headers}} ->
            {:ok, %{Req.Response.new(status: status, headers: headers) | request: request}}

          {^ref, {:error, reason}} ->
            {:error, request, normalize_error(reason)}
        end

      {^ref, {:error, reason}} ->
        {:error, request, normalize_error(reason)}
    end
  end

  defp httpc_stream_loop(request, stream, resp, ref, acc) do
    receive do
      {^ref, {:data, data}} ->
        case stream.(data, resp, acc) do
          {:ok, resp, acc} ->
            httpc_stream_loop(request, stream, resp, ref, acc)

          {:error, resp, exception, acc} ->
            :ok = :httpc.cancel_request(ref)
            {Req.Request.put_private(resp.request, :req_stream_acc, acc), exception}
        end

      {^ref, {:trailers, trailers}} ->
        resp = update_in(resp.trailers, &Map.merge(&1, trailers))
        httpc_stream_loop(request, stream, resp, ref, acc)

      {^ref, :done} ->
        case stream.(:eof, resp, acc) do
          {:ok, resp, acc} ->
            {request, put_in(resp.private[:req_stream_acc], acc)}

          {:error, resp, exception, acc} ->
            {Req.Request.put_private(resp.request, :req_stream_acc, acc), exception}
        end

      {^ref, {:error, reason}} ->
        {put_in(request.private[:req_stream_acc], acc), normalize_error(reason)}
    end
  end

  defp decode_status_and_headers(headers) do
    headers =
      for {name, value} <- headers do
        {List.to_string(name), List.to_string(value)}
      end

    status =
      case List.keyfind(headers, "content-range", 0) do
        {_, _} -> 206
        _ -> 200
      end

    {status, headers}
  end

  # Called from httpc's handler process. Translates httpc events to finch-shaped
  # messages and forwards them to the caller. Drops empty :stream events and
  # diffs stream_end's headers against stream_start to recover real trailers
  # (httpc's stream_end carries the merged response+trailer headers — see
  # httpc_response.erl:611 — so we have to diff to get just the trailers).
  defp httpc_receiver({_ref, :stream, ""}, _caller), do: :ok

  defp httpc_receiver({ref, :stream, data}, caller) do
    send(caller, {ref, {:data, data}})
  end

  defp httpc_receiver({ref, :stream_end, end_headers}, caller) do
    start_headers = Process.delete({__MODULE__, ref}) || []

    # Only headers declared in the response's `Trailer:` field count as trailers;
    # the rest of end_headers are httpc echoing back response headers.
    trailer_names =
      case List.keyfind(start_headers, ~c"trailer", 0) do
        {_, value} ->
          value |> List.to_string() |> String.downcase() |> String.split(~r/,\s*/)

        _ ->
          []
      end

    trailers =
      for {name, _value} = field <- end_headers,
          String.downcase(List.to_string(name)) in trailer_names do
        field
      end

    if trailers != [] do
      send(caller, {ref, {:trailers, decode_trailers(trailers)}})
    end

    send(caller, {ref, :done})
  end

  defp httpc_receiver({ref, :stream_start, headers}, caller) do
    Process.put({__MODULE__, ref}, headers)
    {status, headers} = decode_status_and_headers(headers)
    send(caller, {ref, {:status, status}})
    send(caller, {ref, {:headers, headers}})
  end

  defp httpc_receiver({ref, {{_, status, _}, headers, body}}, caller) do
    headers =
      for {name, value} <- headers do
        {List.to_string(name), List.to_string(value)}
      end

    send(caller, {ref, {:status, status}})
    send(caller, {ref, {:headers, headers}})
    if body != "", do: send(caller, {ref, {:data, body}})
    send(caller, {ref, :done})
  end

  defp httpc_receiver({ref, {:error, reason}}, caller) do
    send(caller, {ref, {:error, reason}})
  end

  defp decode_trailers(trailers) do
    Enum.reduce(trailers, %{}, fn {name, value}, acc ->
      name = List.to_string(name)
      value = List.to_string(value)
      Map.update(acc, name, [value], &(&1 ++ [value]))
    end)
  end

  @doc false
  def httpc_parse_message(ref, {ref, {:data, data}}), do: {:ok, [data: data]}
  def httpc_parse_message(ref, {ref, :done}), do: {:ok, [:done]}
  def httpc_parse_message(ref, {ref, {:trailers, trailers}}), do: {:ok, [trailers: trailers]}
  def httpc_parse_message(ref, {ref, {:error, reason}}), do: {:error, normalize_error(reason)}
  def httpc_parse_message(_, _), do: :unknown

  @doc false
  def httpc_cancel(ref) do
    :httpc.cancel_request(ref)
    httpc_clean_responses(ref)
    :ok
  end

  defp httpc_clean_responses(ref) do
    receive do
      {^ref, _} -> httpc_clean_responses(ref)
    after
      0 -> :ok
    end
  end
end
