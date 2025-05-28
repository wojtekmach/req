defmodule Req.Finch do
  @moduledoc false

  @doc """
  Runs the request using `Finch`.
  """
  def run(request) do
    # URI.parse removes `[` and `]` so we can't check for these. The host
    # should not have `:` so it should be safe to check for it.
    request =
      if !request.options[:inet6] and
           (request.url.host || "") =~ ":" do
        request = put_in(request.options[:inet6], true)
        # ...and have to put them back for host header.
        Req.Request.put_new_header(request, "host", "[#{request.url.host}]")
      else
        request
      end

    finch_name = finch_name(request)

    request_headers =
      if unquote(Req.MixProject.legacy_headers_as_lists?()) do
        request.headers
      else
        for {name, values} <- request.headers,
            value <- values do
          {name, value}
        end
      end

    body =
      case request.body do
        iodata when is_binary(iodata) or is_list(iodata) ->
          iodata

        nil ->
          nil

        enumerable ->
          {:stream, enumerable}
      end

    finch_request =
      Finch.build(request.method, request.url, request_headers, body)
      |> Map.replace!(:unix_socket, request.options[:unix_socket])
      |> add_private_options(request.options[:finch_private])

    finch_options =
      request.options |> Map.take([:receive_timeout, :pool_timeout]) |> Enum.to_list()

    run(request, finch_request, finch_name, finch_options)
  end

  defp run(req, finch_req, finch_name, finch_options) do
    case req.options[:finch_request] do
      fun when is_function(fun, 4) ->
        fun.(req, finch_req, finch_name, finch_options)

      deprecated_fun when is_function(deprecated_fun, 1) ->
        IO.warn(
          "passing a :finch_request function accepting a single argument is deprecated. " <>
            "See Req.Steps.run_finch/1 for more information."
        )

        {req, run_finch_request(deprecated_fun.(finch_req), finch_name, finch_options)}

      nil ->
        case req.into do
          nil ->
            {req, run_finch_request(finch_req, finch_name, finch_options)}

          fun when is_function(fun, 2) ->
            finch_stream_into_fun(req, finch_req, finch_name, finch_options, fun)

          :legacy_self ->
            finch_stream_into_legacy_self(req, finch_req, finch_name, finch_options)

          :self ->
            finch_stream_into_self(req, finch_req, finch_name, finch_options)

          collectable ->
            finch_stream_into_collectable(req, finch_req, finch_name, finch_options, collectable)
        end
    end
  end

  defp finch_stream_into_fun(req, finch_req, finch_name, finch_options, fun) do
    resp = Req.Response.new()

    fun = fn
      {:status, status}, {req, resp} ->
        {:cont, {req, %{resp | status: status}}}

      {:headers, fields}, {req, resp} ->
        resp =
          Enum.reduce(fields, resp, fn {name, value}, resp ->
            Req.Response.put_header(resp, name, value)
          end)

        {:cont, {req, resp}}

      {:data, data}, acc ->
        fun.({:data, data}, acc)

      {:trailers, fields}, {req, resp} ->
        fields = finch_fields_to_map(fields)
        resp = update_in(resp.trailers, &Map.merge(&1, fields))
        {:cont, {req, resp}}
    end

    case Finch.stream_while(finch_req, finch_name, {req, resp}, fun, finch_options) do
      {:ok, acc} ->
        acc

      # TODO: remove when we require Finch 0.20
      {:error, exception} ->
        {req, normalize_error(exception)}

      {:error, exception, _acc} ->
        {req, normalize_error(exception)}
    end
  end

  defp finch_stream_into_collectable(req, finch_req, finch_name, finch_options, collectable) do
    resp = Req.Response.new()

    fun = fn
      {:status, 200}, {nil, req, resp} ->
        {acc, collector} = Collectable.into(collectable)
        {{acc, collector}, req, %{resp | status: 200}}

      {:status, status}, {nil, req, resp} ->
        {acc, collector} = Collectable.into("")
        {{acc, collector}, req, %{resp | status: status}}

      {:headers, fields}, {acc, req, resp} ->
        resp =
          Enum.reduce(fields, resp, fn {name, value}, resp ->
            Req.Response.put_header(resp, name, value)
          end)

        {acc, req, resp}

      {:data, data}, {{acc, collector}, req, resp} ->
        acc = collector.(acc, {:cont, data})
        {{acc, collector}, req, resp}

      {:trailers, fields}, {acc, req, resp} ->
        fields = finch_fields_to_map(fields)
        resp = update_in(resp.trailers, &Map.merge(&1, fields))
        {acc, req, resp}
    end

    case Finch.stream(finch_req, finch_name, {nil, req, resp}, fun, finch_options) do
      {:ok, {{acc, collector}, req, resp}} ->
        acc = collector.(acc, :done)
        {req, %{resp | body: acc}}

      # TODO: remove when we require Finch 0.20
      {:error, exception} ->
        {req, normalize_error(exception)}

      {:error, exception, {nil, _req, _resp}} ->
        {req, normalize_error(exception)}

      {:error, exception, {{acc, collector}, _req, _resp}} ->
        collector.(acc, :halt)
        {req, normalize_error(exception)}
    end
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

  defp normalize_error(%Finch.Error{reason: reason}) do
    %Req.HTTPError{protocol: :http2, reason: reason}
  end

  defp normalize_error(error) do
    error
  end

  defp finch_stream_into_legacy_self(req, finch_req, finch_name, finch_options) do
    ref = Finch.async_request(finch_req, finch_name, finch_options)

    {:status, status} =
      receive do
        {^ref, message} ->
          message
      end

    headers =
      receive do
        {^ref, message} ->
          {:headers, headers} = message

          handle_finch_headers(headers)
      end

    async = %Req.Response.Async{
      pid: self(),
      ref: ref,
      stream_fun: &parse_message/2,
      cancel_fun: &cancel/1
    }

    req = put_in(req.async, async)
    resp = Req.Response.new(status: status, headers: headers)
    {req, resp}
  end

  defp finch_stream_into_self(req, finch_req, finch_name, finch_options) do
    ref = Finch.async_request(finch_req, finch_name, finch_options)

    with {:status, status} <- recv_status(req, ref),
         {:headers, headers} <- recv_headers(req, ref) do
      # TODO: handle trailers
      headers = handle_finch_headers(headers)

      async = %Req.Response.Async{
        pid: self(),
        ref: ref,
        stream_fun: &parse_message/2,
        cancel_fun: &cancel/1
      }

      resp = Req.Response.new(status: status, headers: headers, body: async)
      {req, resp}
    end
  end

  defp recv_status(req, ref) do
    receive do
      {^ref, {:status, status}} ->
        {:status, status}

      {^ref, {:error, exception}} ->
        {req, normalize_error(exception)}
    end
  end

  defp recv_headers(req, ref) do
    receive do
      {^ref, {:headers, headers}} ->
        {:headers, headers}

      {^ref, {:error, exception}} ->
        {req, normalize_error(exception)}
    end
  end

  defp run_finch_request(finch_request, finch_name, finch_options) do
    case Finch.request(finch_request, finch_name, finch_options) do
      {:ok, response} ->
        Req.Response.new(response)

      {:error, exception} ->
        normalize_error(exception)
    end
  end

  defp add_private_options(finch_request, nil) do
    finch_request
  end

  defp add_private_options(finch_request, private_options)
       when is_list(private_options) or is_map(private_options) do
    Enum.reduce(private_options, finch_request, fn {k, v}, acc_finch_req ->
      Finch.Request.put_private(acc_finch_req, k, v)
    end)
  end

  if Req.MixProject.legacy_headers_as_lists?() do
    defp handle_finch_headers(headers), do: headers
  else
    defp handle_finch_headers(headers), do: finch_fields_to_map(headers)
  end

  defp finch_fields_to_map(fields) do
    Enum.reduce(fields, %{}, fn {name, value}, acc ->
      Map.update(acc, name, [value], &(&1 ++ [value]))
    end)
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

  defp parse_message(ref, {ref, {:error, reason}}) do
    {:error, reason}
  end

  defp parse_message(_, _) do
    :unknown
  end

  defp cancel(ref) do
    Finch.cancel_async_request(ref)
    clean_responses(ref)
    :ok
  end

  defp clean_responses(ref) do
    receive do
      {^ref, _} -> clean_responses(ref)
    after
      0 -> :ok
    end
  end

  defp finch_name(request) do
    custom_options? =
      Map.has_key?(request.options, :connect_options) or Map.has_key?(request.options, :inet6)

    cond do
      name = request.options[:finch] ->
        if custom_options? do
          raise ArgumentError, "cannot set both :finch and :connect_options"
        else
          name
        end

      custom_options? ->
        pool_options = pool_options(request.options)

        name =
          pool_options
          |> :erlang.term_to_binary()
          |> :erlang.md5()
          |> Base.url_encode64(padding: false)

        name = Module.concat(Req.FinchSupervisor, "Pool_#{name}")

        case DynamicSupervisor.start_child(
               Req.FinchSupervisor,
               {Finch, name: name, pools: %{default: pool_options}}
             ) do
          {:ok, _} ->
            name

          {:error, {:already_started, _}} ->
            name
        end

      true ->
        Req.Finch
    end
  end

  @doc """
  Returns Finch pool options for the given Req `options`.
  """
  def pool_options(options) when is_map(options) do
    connect_options = options[:connect_options] || []
    inet6_options = options |> Map.take([:inet6]) |> Enum.to_list()
    pool_options = options |> Map.take([:pool_max_idle_time]) |> Enum.to_list()

    Req.Request.validate_options(
      connect_options,
      MapSet.new([
        :timeout,
        :protocols,
        :transport_opts,
        :proxy_headers,
        :proxy,
        :client_settings,
        :hostname,

        # TODO: Remove on Req v1.0
        :protocol
      ])
    )

    transport_opts =
      Keyword.merge(
        Keyword.take(connect_options, [:timeout]) ++ inet6_options,
        Keyword.get(connect_options, :transport_opts, [])
      )

    conn_opts =
      Keyword.take(connect_options, [:hostname, :proxy, :proxy_headers, :client_settings]) ++
        if transport_opts != [] do
          [transport_opts: transport_opts]
        else
          []
        end

    protocols =
      cond do
        protocols = connect_options[:protocols] ->
          protocols

        protocol = connect_options[:protocol] ->
          IO.warn([
            "setting `connect_options: [protocol: protocol]` is deprecated, ",
            "use `connect_options: [protocols: protocols]` instead"
          ])

          [protocol]

        true ->
          [:http1]
      end

    pool_options ++
      [protocols: protocols] ++
      if conn_opts != [] do
        [conn_opts: conn_opts]
      else
        []
      end
  end

  def pool_options(options) when is_list(options) do
    pool_options(Req.new(options).options)
  end
end
