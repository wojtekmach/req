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
        httpc_request(request, httpc_req, httpc_http_options, httpc_options, profile)

      :self ->
        httpc_async(request, httpc_req, httpc_http_options, httpc_options, :self, profile)

      fun when is_function(fun, 2) ->
        httpc_async(request, httpc_req, httpc_http_options, httpc_options, fun, profile)

      collectable ->
        httpc_async(
          request,
          httpc_req,
          httpc_http_options,
          httpc_options,
          {:collectable, collectable},
          profile
        )
    end
  end

  # Enumerables (including Req.Response.Async, which must be consumed in the
  # caller process) and req_body_fun are materialized eagerly.
  defp prepare_body(request) do
    case request.body do
      nil ->
        {request, ""}

      iodata when is_binary(iodata) or is_list(iodata) ->
        {request, iodata}

      fun when is_function(fun, 1) ->
        drain_req_body_fun(fun, request, [])

      {:stream, enumerable} ->
        {request, Enum.to_list(enumerable)}

      enumerable ->
        {request, Enum.to_list(enumerable)}
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

  defp httpc_request(request, httpc_req, httpc_http_options, httpc_options, profile) do
    case :httpc.request(request.method, httpc_req, httpc_http_options, httpc_options, profile) do
      {:ok, {{_, status, _}, headers, body}} ->
        headers =
          for {name, value} <- headers do
            {List.to_string(name), List.to_string(value)}
          end

        {request, Req.Response.new(status: status, headers: headers, body: body)}

      {:error, reason} ->
        {request, normalize_error(reason)}
    end
  after
    stop_profile(profile)
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

  defp httpc_async(request, httpc_req, httpc_http_options, httpc_options, self_or_fun, profile) do
    stream =
      case self_or_fun do
        :self ->
          :self

        _fun_or_collectable ->
          {:self, :once}
      end

    # Use a custom receiver function so we can translate httpc's stream events
    # to the same shape Finch uses (`{ref, {:data, data}}`, `{ref, :done}`, etc.),
    # filter empty :stream events, and route everything to the caller's mailbox.
    caller = self()
    receiver = &httpc_receiver(&1, caller)

    httpc_options = [sync: false, stream: stream, receiver: receiver] ++ httpc_options

    {:ok, ref} =
      :httpc.request(request.method, httpc_req, httpc_http_options, httpc_options, profile)

    receive do
      {^ref, :stream_start, headers} ->
        async = %Req.Response.Async{
          pid: self(),
          ref: ref,
          stream_fun: &httpc_stream/2,
          cancel_fun: &httpc_cancel/1
        }

        {status, headers} = decode_status_and_headers(headers)
        response = Req.Response.new(status: status, headers: headers, body: async)
        {request, response}

      {^ref, :stream_start, headers, pid} ->
        {status, headers} = decode_status_and_headers(headers)
        response = Req.Response.new(status: status, headers: headers)

        case self_or_fun do
          :self ->
            {request, response}

          fun when is_function(fun) ->
            httpc_loop(request, response, ref, pid, fun)

          {:collectable, collectable} ->
            {acc, collector} = Collectable.into(collectable)
            httpc_collect_loop(request, response, ref, pid, acc, collector)
        end

      # httpc only streams 200/206 responses; others arrive complete, so a
      # collectable is ignored and the body is returned as usual.
      {^ref, :complete, {{_, status, _}, headers, body}} ->
        headers =
          for {name, value} <- headers do
            {List.to_string(name), List.to_string(value)}
          end

        response = Req.Response.new(status: status, headers: headers, body: body)
        {request, response}

      {^ref, {:error, reason}} ->
        {request, normalize_error(reason)}
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

  defp httpc_receiver({ref, :stream_start, headers} = msg, caller) do
    Process.put({__MODULE__, ref}, headers)
    send(caller, msg)
  end

  defp httpc_receiver({ref, :stream_start, headers, _pid} = msg, caller) do
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

  defp httpc_loop(request, response, ref, pid, fun) do
    :ok = :httpc.stream_next(pid)

    receive do
      {^ref, {:data, data}} ->
        case fun.({:data, data}, {request, response}) do
          {:cont, {request, response}} ->
            httpc_loop(request, response, ref, pid, fun)

          {:halt, {request, response}} ->
            :ok = :httpc.cancel_request(ref)
            {request, response}
        end

      {^ref, {:trailers, trailers}} ->
        httpc_loop(request, update_in(response.trailers, &Map.merge(&1, trailers)), ref, pid, fun)

      {^ref, :done} ->
        {request, response}

      {^ref, {:error, reason}} ->
        {request, normalize_error(reason)}
    end
  end

  defp httpc_collect_loop(request, response, ref, pid, acc, collector) do
    :ok = :httpc.stream_next(pid)

    receive do
      {^ref, {:data, data}} ->
        httpc_collect_loop(request, response, ref, pid, collector.(acc, {:cont, data}), collector)

      {^ref, {:trailers, trailers}} ->
        response = update_in(response.trailers, &Map.merge(&1, trailers))
        httpc_collect_loop(request, response, ref, pid, acc, collector)

      {^ref, :done} ->
        {request, %{response | body: collector.(acc, :done)}}

      {^ref, {:error, reason}} ->
        collector.(acc, :halt)
        {request, normalize_error(reason)}
    end
  end

  defp stop_profile(:default), do: :ok
  defp stop_profile(profile), do: :inets.stop(:httpc, profile)
end
