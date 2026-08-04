# Experimental httpc adapter to test the adapter contract.

defmodule Req.HTTPC do
  def stream(request, acc, fun, state) when is_function(fun, 4) do
    resp = Req.Response.new(status: nil, body: nil)
    resp = put_in(resp.request, request)

    case prepare_body(request, acc) do
      {:halt, acc} ->
        {:halt, resp, acc, state}

      {:ok, body, acc} ->
        {profile, request, httpc_req, httpc_http_options, httpc_options} = build(request, body)
        resp = put_in(resp.request, request)

        case request.into do
          :self ->
            stream_into_self(
              request,
              httpc_req,
              httpc_http_options,
              httpc_options,
              profile,
              {resp, acc, state},
              fun
            )

          _other ->
            stream_request(
              request,
              httpc_req,
              httpc_http_options,
              httpc_options,
              profile,
              {resp, acc, state},
              fun
            )
        end
    end
  end

  defp stream_request(
         request,
         httpc_req,
         httpc_http_options,
         httpc_options,
         profile,
         s,
         fun
       ) do
    caller = self()
    receiver = &httpc_receiver(&1, caller)
    # Plain :self (no :once flow control): the {:self, :once} stream_next
    # round-trip makes httpc coalesce chunks into one data event and drop a
    # buffered chunk when the socket closes uncleanly.
    httpc_options = [sync: false, stream: :self, receiver: receiver] ++ httpc_options

    {:ok, ref} =
      :httpc.request(request.method, httpc_req, httpc_http_options, httpc_options, profile)

    receive do
      {^ref, :stream_start, headers} ->
        {status, headers} = decode_status_and_headers(headers)

        case stream_events([status: status, headers: headers], s, fun) do
          {:cont, s} ->
            stream_loop(s, ref, fun)

          {tag, {resp, acc, state}} ->
            :ok = :httpc.cancel_request(ref)
            {tag, resp, acc, state}
        end

      {^ref, :complete, {{_, status, _}, headers, body}} ->
        headers = decode_headers(headers)
        events = [status: status, headers: headers] ++ if body == "", do: [], else: [data: body]

        case stream_events(events, s, fun) do
          {:cont, {resp, acc, state}} ->
            {:ok, resp, acc, state}

          {tag, {resp, acc, state}} ->
            {tag, resp, acc, state}
        end

      {^ref, {:error, reason}} ->
        {resp, acc, state} = s
        {{:error, normalize_error(reason)}, resp, acc, state}
    end
  after
    stop_profile(profile)
  end

  defp stream_loop(s, ref, fun) do
    receive do
      {^ref, {:data, data}} ->
        case stream_events([data: data], s, fun) do
          {:cont, s} ->
            stream_loop(s, ref, fun)

          {tag, {resp, acc, state}} ->
            :ok = :httpc.cancel_request(ref)
            {tag, resp, acc, state}
        end

      {^ref, {:trailers, trailers}} ->
        case stream_events([trailers: trailers], s, fun) do
          {:cont, s} ->
            stream_loop(s, ref, fun)

          {tag, {resp, acc, state}} ->
            :ok = :httpc.cancel_request(ref)
            {tag, resp, acc, state}
        end

      {^ref, :done} ->
        {resp, acc, state} = s
        {:ok, resp, acc, state}

      {^ref, {:error, reason}} ->
        {resp, acc, state} = s
        {{:error, normalize_error(reason)}, resp, acc, state}
    end
  end

  defp stream_into_self(
         request,
         httpc_req,
         httpc_http_options,
         httpc_options,
         profile,
         s,
         fun
       ) do
    caller = self()
    receiver = &httpc_receiver(&1, caller)
    httpc_options = [sync: false, stream: :self, receiver: receiver] ++ httpc_options

    {:ok, ref} =
      :httpc.request(request.method, httpc_req, httpc_http_options, httpc_options, profile)

    receive do
      {^ref, :stream_start, headers} ->
        {status, headers} = decode_status_and_headers(headers)

        case stream_events([status: status, headers: headers], s, fun) do
          {:cont, {resp, acc, state}} ->
            async = %Req.Response.Async{
              pid: self(),
              ref: ref,
              stream_fun: &httpc_stream/2,
              cancel_fun: &httpc_cancel/1
            }

            resp = put_in(resp.body, async)
            {:ok, resp, acc, state}

          {tag, {resp, acc, state}} ->
            httpc_cancel(ref)
            {tag, resp, acc, state}
        end

      # httpc only streams 200/206 responses; others arrive complete.
      {^ref, :complete, {{_, status, _}, headers, body}} ->
        headers = decode_headers(headers)

        case stream_events([status: status, headers: headers], s, fun) do
          {:cont, {resp, acc, state}} ->
            resp = put_in(resp.body, body)
            {:ok, resp, acc, state}

          {tag, {resp, acc, state}} ->
            {tag, resp, acc, state}
        end

      {^ref, {:error, reason}} ->
        {resp, acc, state} = s
        {{:error, normalize_error(reason)}, resp, acc, state}
    end
  after
    stop_profile(profile)
  end

  defp stream_events([], s, _fun) do
    {:cont, s}
  end

  defp stream_events([event | events], {resp, acc, state}, fun) do
    resp =
      case event do
        {:status, status} ->
          put_in(resp.status, status)

        {:headers, headers} ->
          put_in(resp.headers, Req.Fields.new_without_normalize_with_duplicates(headers))

        {:trailers, trailers} ->
          put_in(resp.trailers, Req.Fields.new_without_normalize_with_duplicates(trailers))

        _ ->
          resp
      end

    case fun.(event, resp, acc, state) do
      {:cont, resp, acc, state} ->
        stream_events(events, {resp, acc, state}, fun)

      {tag, resp, acc, state} ->
        {tag, {resp, acc, state}}
    end
  end

  defp build(request, body) do
    {profile, request, httpc_http_options, httpc_options} = prepare_request(request)
    httpc_url = request.url |> URI.to_string() |> String.to_charlist()

    httpc_headers =
      for {name, value} <- Req.Fields.get_list(request.headers) do
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

    {profile, request, httpc_req, httpc_http_options, httpc_options}
  end

  defp prepare_body(request, acc) do
    case request.body do
      nil ->
        {:ok, "", acc}

      iodata when is_binary(iodata) or is_list(iodata) ->
        {:ok, iodata, acc}

      fun when is_function(fun, 1) ->
        drain_req_body_fun(fun, acc, [])

      %Req.Response.Async{} = async ->
        # Async's Enumerable reads response chunks from this (the caller's) process
        # mailbox, so it must be consumed here rather than driven from httpc's process.
        {:ok, Enum.to_list(async), acc}

      {:stream, enumerable} ->
        {:ok, stream_body(request, enumerable), acc}

      enumerable ->
        {:ok, stream_body(request, enumerable), acc}
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

  defp drain_req_body_fun(fun, acc, chunks) do
    case fun.(acc) do
      {:data, chunk, acc} ->
        drain_req_body_fun(fun, acc, [chunks | chunk])

      {:done, chunk, acc} ->
        {:ok, [chunks | chunk], acc}

      {:done, acc} ->
        {:ok, chunks, acc}

      {:halt, acc} ->
        {:halt, acc}

      other ->
        raise "expected req_body_fun to return {:data, chunk, acc}, {:done, chunk, acc}, " <>
                "{:done, acc}, or {:halt, acc}, got: #{inspect(other)}"
    end
  end

  defp prepare_request(request) do
    httpc_http_options = [
      autoredirect: false,
      autoretry: 0,
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
    if :http2 in (connect_options[:protocols] || []) do
      raise ArgumentError, "httpc adapter does not support HTTP/2"
    end

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

  defp normalize_error(:socket_closed_remotely) do
    %Req.TransportError{reason: :closed}
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

  defp decode_status_and_headers(headers) do
    headers = decode_headers(headers)

    status =
      case List.keyfind(headers, "content-range", 0) do
        {_, _} -> 206
        _ -> 200
      end

    {status, headers}
  end

  defp decode_headers(headers) do
    for {name, value} <- headers do
      {List.to_string(name), List.to_string(value)}
    end
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

  defp httpc_receiver({ref, :stream_start, headers} = msg, caller) do
    Process.put({__MODULE__, ref}, headers)
    send(caller, msg)
  end

  defp httpc_receiver({ref, {{_, _, _}, _, _} = result}, caller) do
    send(caller, {ref, :complete, result})
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
  def httpc_stream(ref, {ref, {:data, data}}), do: {:ok, [data: data]}
  def httpc_stream(ref, {ref, :done}), do: {:ok, [:done]}
  def httpc_stream(ref, {ref, {:trailers, trailers}}), do: {:ok, [trailers: trailers]}
  def httpc_stream(ref, {ref, {:error, reason}}), do: {:error, normalize_error(reason)}
  def httpc_stream(_, _), do: :unknown

  @doc false
  def httpc_cancel(ref) do
    :httpc.cancel_request(ref)
  end

  defp stop_profile(:default), do: :ok
  defp stop_profile(profile), do: :inets.stop(:httpc, profile)
end
