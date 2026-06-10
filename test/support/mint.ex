# Experimental Mint adapter to test the adapter contract.

defmodule Req.Mint do
  require Mint.HTTP

  def run(request) do
    # Mint derives the host header from the address, producing an invalid
    # `::1:port` for IPv6 hosts, so set a bracketed one ourselves.
    request =
      if (request.url.host || "") =~ ":" do
        Req.Request.put_new_header(request, "host", "[#{request.url.host}]")
      else
        request
      end

    case connect(request) do
      {:ok, conn} ->
        send_request(request, conn)

      {:error, exception} ->
        {request, exception}
    end
  end

  defp connect(request) do
    connect_options = request.options[:connect_options] || []

    transport_opts =
      Keyword.merge(
        Keyword.take(connect_options, [:timeout]),
        Keyword.get(connect_options, :transport_opts, [])
      )

    transport_opts =
      if request.options[:inet6] == true or (request.url.host || "") =~ ":" do
        Keyword.put(transport_opts, :inet6, true)
      else
        transport_opts
      end

    scheme =
      case request.url.scheme do
        "https" ->
          :https

        _ ->
          :http
      end

    {address, port, address_options} =
      if unix_socket = request.options[:unix_socket] do
        {{:local, unix_socket}, 0, [hostname: request.url.host]}
      else
        {request.url.host, request.url.port, []}
      end

    options =
      [
        mode: :passive,
        protocols: connect_options[:protocols] || [:http1],
        transport_opts: transport_opts
      ] ++ address_options

    case Mint.HTTP.connect(scheme, address, port, options) do
      {:ok, conn} ->
        {:ok, conn}

      {:error, exception} ->
        {:error, normalize_error(exception)}
    end
  end

  defp send_request(request, conn) do
    method = request.method |> Atom.to_string() |> String.upcase()

    headers =
      for {name, values} <- request.headers,
          # TODO: remove List.wrap on Req 1.0
          value <- List.wrap(values) do
        {name, value}
      end

    {body, stream_body} =
      case request.body do
        nil ->
          {nil, nil}

        iodata when is_binary(iodata) or is_list(iodata) ->
          {iodata, nil}

        fun when is_function(fun, 1) ->
          {:stream, fun}

        {:stream, enumerable} ->
          {:stream, enumerable}

        enumerable ->
          {:stream, enumerable}
      end

    case Mint.HTTP.request(conn, method, request_path(request.url), headers, body) do
      {:ok, conn, ref} ->
        case stream_request_body(request, conn, ref, stream_body) do
          {:ok, request, conn} ->
            recv_response(request, conn, ref)

          {:halt, request, conn} ->
            Mint.HTTP.close(conn)
            {request, Req.Response.new(status: nil, body: "")}

          {:error, request, conn, error} ->
            Mint.HTTP.close(conn)
            {request, normalize_error(error)}
        end

      {:error, conn, error} ->
        Mint.HTTP.close(conn)
        {request, normalize_error(error)}
    end
  end

  defp request_path(url) do
    path = url.path || "/"

    if url.query in [nil, ""] do
      path
    else
      path <> "?" <> url.query
    end
  end

  defp stream_request_body(request, conn, _ref, nil) do
    {:ok, request, conn}
  end

  defp stream_request_body(request, conn, ref, req_body_fun) when is_function(req_body_fun, 1) do
    case req_body_fun.(request) do
      {:data, chunk, request} ->
        case Mint.HTTP.stream_request_body(conn, ref, chunk) do
          {:ok, conn} ->
            stream_request_body(request, conn, ref, req_body_fun)

          {:error, conn, error} ->
            {:error, request, conn, error}
        end

      {:done, request} ->
        case Mint.HTTP.stream_request_body(conn, ref, :eof) do
          {:ok, conn} ->
            {:ok, request, conn}

          {:error, conn, error} ->
            {:error, request, conn, error}
        end

      {:halt, request} ->
        {:halt, request, conn}

      other ->
        raise "expected req_body_fun to return {:data, chunk, request}, {:done, request}, or {:halt, request}, got: #{inspect(other)}"
    end
  end

  defp stream_request_body(request, conn, ref, enumerable) do
    result =
      Enum.reduce_while(enumerable, {:ok, conn}, fn chunk, {:ok, conn} ->
        case Mint.HTTP.stream_request_body(conn, ref, chunk) do
          {:ok, conn} ->
            {:cont, {:ok, conn}}

          {:error, conn, error} ->
            {:halt, {:error, conn, error}}
        end
      end)

    with {:ok, conn} <- result,
         {:ok, conn} <- Mint.HTTP.stream_request_body(conn, ref, :eof) do
      {:ok, request, conn}
    else
      {:error, conn, error} ->
        {:error, request, conn, error}
    end
  end

  defp recv_response(request, conn, ref) do
    timeouts = %{
      receive_timeout: request.options[:receive_timeout] || 15_000,
      deadline: deadline(request.options[:request_timeout])
    }

    case request.into do
      nil ->
        recv_into_nil(request, conn, ref, timeouts)

      fun when is_function(fun, 2) ->
        recv_into_fun(request, conn, ref, timeouts, fun)

      :self ->
        recv_into_self(request, conn, ref, timeouts)

      collectable ->
        recv_into_collectable(request, conn, ref, timeouts, collectable)
    end
  end

  defp recv_into_nil(request, conn, ref, timeouts) do
    acc = %{status: nil, headers: [], body: [], trailers: []}

    fun = fn
      {:status, status}, {request, acc} ->
        {:cont, {request, %{acc | status: status}}}

      {:headers, fields}, {request, acc} ->
        {:cont, {request, %{acc | headers: acc.headers ++ fields}}}

      {:data, data}, {request, acc} ->
        {:cont, {request, %{acc | body: [acc.body | data]}}}

      {:trailers, fields}, {request, acc} ->
        {:cont, {request, %{acc | trailers: acc.trailers ++ fields}}}
    end

    case recv_stream(conn, ref, {request, acc}, fun, timeouts) do
      {:ok, {request, acc}} ->
        response =
          Req.Response.new(
            status: acc.status,
            headers: acc.headers,
            body: IO.iodata_to_binary(acc.body),
            trailers: fields_to_map(acc.trailers)
          )

        {request, response}

      {:error, {request, _acc}, exception} ->
        {request, exception}
    end
  end

  defp recv_into_fun(request, conn, ref, timeouts, fun) do
    stream_fun = fn
      {:status, status}, {request, resp} ->
        {:cont, {request, %{resp | status: status}}}

      {:headers, fields}, {request, resp} ->
        resp =
          Enum.reduce(fields, resp, fn {name, value}, resp ->
            Req.Response.put_header(resp, name, value)
          end)

        {:cont, {request, resp}}

      {:data, data}, acc ->
        fun.({:data, data}, acc)

      {:trailers, fields}, {request, resp} ->
        resp = update_in(resp.trailers, &Map.merge(&1, fields_to_map(fields)))
        {:cont, {request, resp}}
    end

    case recv_stream(conn, ref, {request, Req.Response.new()}, stream_fun, timeouts) do
      {:ok, {request, response}} ->
        {request, response}

      {:error, {request, _response}, exception} ->
        {request, exception}
    end
  end

  defp recv_into_collectable(request, conn, ref, timeouts, collectable) do
    stream_fun = fn
      {:status, 200}, {request, {nil, resp}} ->
        {acc, collector} = Collectable.into(collectable)
        {:cont, {request, {{acc, collector}, %{resp | status: 200}}}}

      {:status, status}, {request, {nil, resp}} ->
        {acc, collector} = Collectable.into("")
        {:cont, {request, {{acc, collector}, %{resp | status: status}}}}

      {:headers, fields}, {request, {collector_acc, resp}} ->
        resp =
          Enum.reduce(fields, resp, fn {name, value}, resp ->
            Req.Response.put_header(resp, name, value)
          end)

        {:cont, {request, {collector_acc, resp}}}

      {:data, data}, {request, {{acc, collector}, resp}} ->
        acc = collector.(acc, {:cont, data})
        {:cont, {request, {{acc, collector}, resp}}}

      {:trailers, fields}, {request, {collector_acc, resp}} ->
        resp = update_in(resp.trailers, &Map.merge(&1, fields_to_map(fields)))
        {:cont, {request, {collector_acc, resp}}}
    end

    case recv_stream(conn, ref, {request, {nil, Req.Response.new()}}, stream_fun, timeouts) do
      {:ok, {request, {{acc, collector}, resp}}} ->
        acc = collector.(acc, :done)
        {request, %{resp | body: acc}}

      {:error, {request, {nil, _resp}}, exception} ->
        {request, exception}

      {:error, {request, {{acc, collector}, _resp}}, exception} ->
        collector.(acc, :halt)
        {request, exception}
    end
  end

  # Streams response entries into fun until :done, :halt, or error. Headers
  # received after the first body chunk are passed as {:trailers, fields}.
  defp recv_stream(conn, ref, acc, fun, timeouts) do
    case recv_loop(conn, ref, :headers, acc, fun, timeouts) do
      {:ok, conn, acc} ->
        Mint.HTTP.close(conn)
        {:ok, acc}

      {:error, conn, acc, exception} ->
        Mint.HTTP.close(conn)
        {:error, acc, exception}
    end
  end

  defp recv_loop(conn, ref, phase, acc, fun, timeouts) do
    case Mint.HTTP.recv(conn, 0, recv_timeout(timeouts)) do
      {:ok, conn, entries} ->
        case handle_entries(entries, ref, phase, acc, fun) do
          {:cont, phase, acc} ->
            recv_loop(conn, ref, phase, acc, fun, timeouts)

          {:done, acc} ->
            {:ok, conn, acc}

          {:halt, acc} ->
            {:ok, conn, acc}

          {:error, acc, error} ->
            {:error, conn, acc, normalize_error(error)}
        end

      {:error, conn, error, _entries} ->
        {:error, conn, acc, normalize_error(error)}
    end
  end

  defp handle_entries([], _ref, phase, acc, _fun) do
    {:cont, phase, acc}
  end

  defp handle_entries([entry | rest], ref, phase, acc, fun) do
    case entry do
      {:status, ^ref, status} ->
        apply_fun({:status, status}, rest, ref, phase, acc, fun)

      {:headers, ^ref, fields} when phase == :headers ->
        apply_fun({:headers, fields}, rest, ref, phase, acc, fun)

      {:headers, ^ref, fields} ->
        apply_fun({:trailers, fields}, rest, ref, phase, acc, fun)

      {:data, ^ref, data} ->
        apply_fun({:data, data}, rest, ref, :body, acc, fun)

      {:done, ^ref} ->
        {:done, acc}

      {:error, ^ref, error} ->
        {:error, acc, error}
    end
  end

  defp apply_fun(event, rest, ref, phase, acc, fun) do
    case fun.(event, acc) do
      {:cont, acc} ->
        handle_entries(rest, ref, phase, acc, fun)

      {:halt, acc} ->
        {:halt, acc}
    end
  end

  # into: :self receives status and headers synchronously, then hands the
  # connection over to a spawned process that forwards Finch-shaped messages
  # ({ref, {:data, data}}, {ref, :done}, etc.) to the caller's mailbox.
  defp recv_into_self(request, conn, ref, timeouts) do
    case recv_status_and_headers(conn, ref, timeouts, nil, []) do
      {:ok, conn, status, headers, rest} ->
        async = %Req.Response.Async{
          pid: self(),
          ref: ref,
          stream_fun: &parse_message/2,
          cancel_fun: start_owner(conn, ref, rest, timeouts)
        }

        response =
          Req.Response.new(status: status, headers: fields_to_map(headers), body: async)

        {request, response}

      {:error, conn, exception} ->
        Mint.HTTP.close(conn)
        {request, exception}
    end
  end

  defp recv_status_and_headers(conn, ref, timeouts, status, headers) do
    case Mint.HTTP.recv(conn, 0, recv_timeout(timeouts)) do
      {:ok, conn, entries} ->
        case split_status_and_headers(entries, ref, status, headers) do
          {:ok, status, headers, rest} ->
            {:ok, conn, status, headers, rest}

          {:cont, status, headers} ->
            recv_status_and_headers(conn, ref, timeouts, status, headers)
        end

      {:error, conn, error, _entries} ->
        {:error, conn, normalize_error(error)}
    end
  end

  defp split_status_and_headers([entry | rest], ref, status, headers) do
    case entry do
      {:status, ^ref, status} ->
        split_status_and_headers(rest, ref, status, headers)

      {:headers, ^ref, fields} ->
        {:ok, status, headers ++ fields, rest}

      {:done, ^ref} ->
        {:ok, status, headers, [{:done, ref}]}
    end
  end

  defp split_status_and_headers([], _ref, status, headers) do
    {:cont, status, headers}
  end

  defp start_owner(conn, ref, early_entries, timeouts) do
    caller = self()

    owner =
      spawn_link(fn ->
        receive do
          {:go, conn} ->
            {:ok, conn} = Mint.HTTP.set_mode(conn, :active)

            if forward_entries(early_entries, ref, caller) == :cont do
              owner_loop(conn, ref, caller, timeouts)
            end
        end
      end)

    {:ok, conn} = Mint.HTTP.controlling_process(conn, owner)
    send(owner, {:go, conn})

    fn ^ref ->
      monitor = Process.monitor(owner)
      send(owner, :cancel)

      receive do
        {:DOWN, ^monitor, _, _, _} ->
          :ok
      after
        1000 ->
          :ok
      end

      flush(ref)
    end
  end

  defp owner_loop(conn, ref, caller, timeouts) do
    receive do
      :cancel ->
        Mint.HTTP.close(conn)

      message when Mint.HTTP.is_connection_message(conn, message) ->
        case Mint.HTTP.stream(conn, message) do
          {:ok, conn, entries} ->
            case forward_entries(entries, ref, caller) do
              :cont ->
                owner_loop(conn, ref, caller, timeouts)

              :done ->
                Mint.HTTP.close(conn)
            end

          {:error, conn, error, entries} ->
            forward_entries(entries, ref, caller)
            send(caller, {ref, {:error, normalize_error(error)}})
            Mint.HTTP.close(conn)
        end
    after
      timeouts.receive_timeout ->
        send(caller, {ref, {:error, %Req.TransportError{reason: :timeout}}})
        Mint.HTTP.close(conn)
    end
  end

  defp forward_entries([], _ref, _caller) do
    :cont
  end

  defp forward_entries([entry | rest], ref, caller) do
    case entry do
      {:data, ^ref, data} ->
        send(caller, {ref, {:data, data}})
        forward_entries(rest, ref, caller)

      {:headers, ^ref, fields} ->
        send(caller, {ref, {:trailers, fields_to_map(fields)}})
        forward_entries(rest, ref, caller)

      {:done, ^ref} ->
        send(caller, {ref, :done})
        :done

      {:error, ^ref, error} ->
        send(caller, {ref, {:error, normalize_error(error)}})
        :done
    end
  end

  defp parse_message(ref, {ref, {:data, data}}) do
    {:ok, [data: data]}
  end

  defp parse_message(ref, {ref, :done}) do
    {:ok, [:done]}
  end

  defp parse_message(ref, {ref, {:trailers, trailers}}) do
    {:ok, [trailers: trailers]}
  end

  defp parse_message(ref, {ref, {:error, error}}) do
    {:error, error}
  end

  defp parse_message(_ref, _message) do
    :unknown
  end

  defp flush(ref) do
    receive do
      {^ref, _} ->
        flush(ref)
    after
      0 ->
        :ok
    end
  end

  defp deadline(nil) do
    nil
  end

  defp deadline(request_timeout) do
    System.monotonic_time(:millisecond) + request_timeout
  end

  defp recv_timeout(%{receive_timeout: receive_timeout, deadline: nil}) do
    receive_timeout
  end

  defp recv_timeout(%{receive_timeout: receive_timeout, deadline: deadline}) do
    min(receive_timeout, max(deadline - System.monotonic_time(:millisecond), 0))
  end

  defp fields_to_map(fields) do
    Enum.reduce(fields, %{}, fn {name, value}, acc ->
      Map.update(acc, name, [value], &(&1 ++ [value]))
    end)
  end

  defp normalize_error(%Mint.TransportError{reason: reason}) do
    %Req.TransportError{reason: reason}
  end

  defp normalize_error(%Mint.HTTPError{module: Mint.HTTP1, reason: reason}) do
    %Req.HTTPError{protocol: :http1, reason: reason}
  end

  defp normalize_error(%Mint.HTTPError{module: Mint.HTTP2, reason: reason}) do
    %Req.HTTPError{protocol: :http2, reason: reason}
  end

  defp normalize_error(error) do
    error
  end
end
