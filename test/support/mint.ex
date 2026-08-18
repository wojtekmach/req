# Experimental Mint adapter to test the adapter contract.

defmodule Req.Mint do
  require Mint.HTTP

  def stream(req, acc, fun, state) when is_function(fun, 4) do
    # Mint derives the host header from the address, producing an invalid
    # `::1:port` for IPv6 hosts, so set a bracketed one ourselves.
    req =
      if (req.url.host || "") =~ ":" do
        Req.Request.put_new_header(req, "host", "[#{req.url.host}]")
      else
        req
      end

    resp = Req.Response.new(status: nil, body: nil)
    resp = put_in(resp.request, req)

    case connect(req) do
      {:ok, conn} ->
        case start_request(req, conn, acc) do
          {:ok, conn, ref, acc} ->
            case req.into do
              :self ->
                stream_into_self(req, conn, ref, resp, acc, fun, state)

              _other ->
                stream_response(req, conn, ref, resp, acc, fun, state)
            end

          {:halt, conn, acc} ->
            Mint.HTTP.close(conn)
            {:halt, resp, acc, state}

          {:error, conn, error, acc} ->
            Mint.HTTP.close(conn)
            {{:error, normalize_error(error)}, resp, acc, state}
        end

      {:error, exception} ->
        {{:error, exception}, resp, acc, state}
    end
  end

  defp stream_response(req, conn, ref, resp, acc, fun, state) do
    timeouts = %{
      receive_timeout: req.options[:receive_timeout] || 15_000,
      deadline: deadline(req.options[:request_timeout])
    }

    stream_fun = fn
      {:status, status}, {resp, acc, state} ->
        resp = put_in(resp.status, status)

        case fun.({:status, status}, resp, acc, state) do
          {:ok, resp, acc, state} ->
            {:cont, {resp, acc, state}}

          {:halt, resp, acc, state} ->
            {:halt, {resp, acc, state}}

          {{:error, exception}, resp, acc, state} ->
            {:error, {resp, acc, state}, exception}
        end

      {:headers, headers}, {resp, acc, state} ->
        resp = put_in(resp.headers, Req.Fields.new_without_normalize_with_duplicates(headers))

        case fun.({:headers, headers}, resp, acc, state) do
          {:ok, resp, acc, state} ->
            {:cont, {resp, acc, state}}

          {:halt, resp, acc, state} ->
            {:halt, {resp, acc, state}}

          {{:error, exception}, resp, acc, state} ->
            {:error, {resp, acc, state}, exception}
        end

      {:data, data}, {resp, acc, state} ->
        case fun.({:data, data}, resp, acc, state) do
          {:ok, resp, acc, state} ->
            {:cont, {resp, acc, state}}

          {:halt, resp, acc, state} ->
            {:halt, {resp, acc, state}}

          {{:error, exception}, resp, acc, state} ->
            {:error, {resp, acc, state}, exception}
        end

      {:trailers, trailers}, {resp, acc, state} ->
        resp =
          put_in(resp.trailers, Req.Fields.new_without_normalize_with_duplicates(trailers))

        case fun.({:trailers, trailers}, resp, acc, state) do
          {:ok, resp, acc, state} ->
            {:cont, {resp, acc, state}}

          {:halt, resp, acc, state} ->
            {:halt, {resp, acc, state}}

          {{:error, exception}, resp, acc, state} ->
            {:error, {resp, acc, state}, exception}
        end
    end

    case recv_stream(conn, ref, {resp, acc, state}, stream_fun, timeouts) do
      {:ok, {resp, acc, state}} ->
        {:ok, resp, acc, state}

      {:halt, {resp, acc, state}} ->
        {:halt, resp, acc, state}

      {:error, {resp, acc, state}, exception} ->
        {{:error, exception}, resp, acc, state}
    end
  end

  defp stream_into_self(req, conn, ref, resp, acc, fun, state) do
    timeouts = %{
      receive_timeout: req.options[:receive_timeout] || 15_000,
      deadline: deadline(req.options[:request_timeout])
    }

    case recv_status_and_headers(conn, ref, timeouts, nil, []) do
      {:ok, conn, status, headers, rest} ->
        resp = put_in(resp.status, status)

        case fun.({:status, status}, resp, acc, state) do
          {:ok, resp, acc, state} ->
            resp =
              put_in(resp.headers, Req.Fields.new_without_normalize_with_duplicates(headers))

            case fun.({:headers, headers}, resp, acc, state) do
              {:ok, resp, acc, state} ->
                async = %Req.Response.Async{
                  pid: self(),
                  ref: ref,
                  stream_fun: &parse_message/2,
                  cancel_fun: start_owner(conn, ref, rest, timeouts)
                }

                resp = put_in(resp.body, async)
                {:ok, resp, acc, state}

              {:halt, resp, acc, state} ->
                Mint.HTTP.close(conn)
                {:halt, resp, acc, state}

              {{:error, exception}, resp, acc, state} ->
                Mint.HTTP.close(conn)
                {{:error, exception}, resp, acc, state}
            end

          {:halt, resp, acc, state} ->
            Mint.HTTP.close(conn)
            {:halt, resp, acc, state}

          {{:error, exception}, resp, acc, state} ->
            Mint.HTTP.close(conn)
            {{:error, exception}, resp, acc, state}
        end

      {:error, conn, exception} ->
        Mint.HTTP.close(conn)
        {{:error, exception}, resp, acc, state}
    end
  end

  defp connect(req) do
    connect_options = req.options[:connect_options] || []

    transport_opts =
      Keyword.merge(
        Keyword.take(connect_options, [:timeout]),
        Keyword.get(connect_options, :transport_opts, [])
      )

    transport_opts =
      if req.options[:inet6] == true or (req.url.host || "") =~ ":" do
        Keyword.put(transport_opts, :inet6, true)
      else
        transport_opts
      end

    scheme =
      case req.url.scheme do
        "http" -> :http
        "https" -> :https
      end

    transport_opts =
      if scheme == :https do
        transport_opts
      else
        # when redirecting from https to http, we may still have these ssl options which we need
        # to drop because mint errors otherwise
        Keyword.drop(transport_opts, [:cacertfile, :certfile, :keyfile])
      end

    {address, port, address_options} =
      if unix_socket = req.options[:unix_socket] do
        {{:local, unix_socket}, 0, [hostname: req.url.host]}
      else
        {req.url.host, req.url.port, []}
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

  defp start_request(req, conn, acc) do
    method = req.method |> Atom.to_string() |> String.upcase()

    headers = Req.Fields.get_list(req.headers)

    {body, stream_body} =
      case req.body do
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

    case Mint.HTTP.request(conn, method, request_path(req.url), headers, body) do
      {:ok, conn, ref} ->
        case stream_request_body(conn, ref, stream_body, acc) do
          {:ok, conn, acc} ->
            {:ok, conn, ref, acc}

          {:halt, conn, acc} ->
            {:halt, conn, acc}

          {:error, conn, error, acc} ->
            {:error, conn, error, acc}
        end

      {:error, conn, error} ->
        {:error, conn, error, acc}
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

  defp stream_request_body(conn, _ref, nil, acc) do
    {:ok, conn, acc}
  end

  defp stream_request_body(conn, ref, req_body_fun, acc) when is_function(req_body_fun, 1) do
    case req_body_fun.(acc) do
      {:data, chunk, acc} ->
        case Mint.HTTP.stream_request_body(conn, ref, chunk) do
          {:ok, conn} ->
            stream_request_body(conn, ref, req_body_fun, acc)

          {:error, conn, error} ->
            {:error, conn, error, acc}
        end

      {:done, chunk, acc} ->
        with {:ok, conn} <- Mint.HTTP.stream_request_body(conn, ref, chunk),
             {:ok, conn} <- Mint.HTTP.stream_request_body(conn, ref, :eof) do
          {:ok, conn, acc}
        else
          {:error, conn, error} ->
            {:error, conn, error, acc}
        end

      {:done, acc} ->
        case Mint.HTTP.stream_request_body(conn, ref, :eof) do
          {:ok, conn} ->
            {:ok, conn, acc}

          {:error, conn, error} ->
            {:error, conn, error, acc}
        end

      {:halt, acc} ->
        {:halt, conn, acc}

      other ->
        raise "expected req_body_fun to return {:data, chunk, acc}, {:done, chunk, acc}, " <>
                "{:done, acc}, or {:halt, acc}, got: #{inspect(other)}"
    end
  end

  defp stream_request_body(conn, ref, enumerable, acc) do
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
      {:ok, conn, acc}
    else
      {:error, conn, error} ->
        {:error, conn, error, acc}
    end
  end

  # Streams response entries into fun until :done, :halt, or error. Headers
  # received after the first body chunk are passed as {:trailers, fields}.
  defp recv_stream(conn, ref, acc, fun, timeouts) do
    case recv_loop(conn, ref, :headers, acc, fun, timeouts) do
      {:ok, conn, acc} ->
        Mint.HTTP.close(conn)
        {:ok, acc}

      {:halt, conn, acc} ->
        Mint.HTTP.close(conn)
        {:halt, acc}

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
            {:halt, conn, acc}

          {:error, acc, error} ->
            {:error, conn, acc, normalize_error(error)}
        end

      {:error, conn, error, entries} ->
        case handle_entries(entries, ref, phase, acc, fun) do
          {:cont, _phase, acc} ->
            {:error, conn, acc, normalize_error(error)}

          {:done, acc} ->
            {:ok, conn, acc}

          {:halt, acc} ->
            {:halt, conn, acc}

          {:error, acc, entries_error} ->
            {:error, conn, acc, normalize_error(entries_error)}
        end
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

      {:error, acc, error} ->
        {:error, acc, error}
    end
  end

  # into: :self receives status and headers synchronously, then hands the
  # connection over to a spawned process that forwards Finch-shaped messages
  # ({ref, {:data, data}}, {ref, :done}, etc.) to the caller's mailbox.
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
        send(caller, {ref, {:trailers, fields}})
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
