# TODO: When Finch v0.22 is out, remove "requires Finch main" from docs.

defmodule Req.Finch do
  @moduledoc false

  @finch_build_options [:pool_tag, :unix_socket]
  @finch_request_options [:pool_timeout, :receive_timeout, :request_timeout, :pool_strategy]

  def child_spec(options) do
    {name, options} = Keyword.pop!(options, :name)
    Finch.child_spec(name: name, pools: %{default: pool_options(options)})
  end

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

    {finch_name, build_options, request_options} = finch_name_options(request)

    # TODO: Remove when :finch_request is removed
    if match?(
         %{body: req_body_fun, options: %{finch_request: finch_request_fun}}
         when is_function(req_body_fun, 1) and is_function(finch_request_fun),
         request
       ) do
      raise ArgumentError, ":finch_request does not support body set to req_body_fun"
    end

    if is_function(request.body, 1) and request.options[:into] == :self do
      raise ArgumentError, "into: :self does not support body set to req_body_fun"
    end

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

        req_body_fun when is_function(req_body_fun, 1) ->
          wrapped_req_body_fun = fn
            {request, state} ->
              case req_body_fun.(request) do
                {:data, chunk, request} ->
                  {:data, chunk, {request, state}}

                {:done, request} ->
                  {:done, {request, state}}

                {:halt, request} ->
                  {:halt, {request, state}}

                other ->
                  raise "expected req_body_fun to return {:data, chunk, request}, {:done, request}, or {:halt, request}, got: #{inspect(other)}"
              end
          end

          {:stream, wrapped_req_body_fun}

        enumerable ->
          {:stream, enumerable}
      end

    build_options =
      if unix_socket = request.options[:unix_socket] do
        Keyword.put_new(build_options, :unix_socket, unix_socket)
      else
        build_options
      end

    finch_request =
      Finch.build(request.method, request.url, request_headers, body, build_options)
      |> add_private_options(request.options[:finch_private])

    finch_options =
      request.options
      |> Map.take([:receive_timeout, :pool_timeout, :request_timeout])
      |> Enum.to_list()
      |> Keyword.merge(request_options)

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

        finch_stream(req, deprecated_fun.(finch_req), finch_name, finch_options)

      nil ->
        case req.into do
          nil ->
            finch_stream(req, finch_req, finch_name, finch_options)

          :self ->
            finch_stream_into_self(req, finch_req, finch_name, finch_options)
        end
    end
  end

  defp finch_stream(req, finch_req, finch_name, finch_options) do
    stream = req.stream
    acc = req.private[:req_stream_acc]

    resp = %{Req.Response.new() | request: req, status: nil}

    stream_fun = fn
      {:status, status}, {request, {resp, acc}} ->
        {:cont, {request, {%{resp | status: status}, acc}}}

      {:headers, headers}, {request, {resp, acc}} ->
        resp = update_in(resp.headers, &Req.Fields.prepend(&1, headers))
        {:cont, {request, {resp, acc}}}

      {:data, data}, {request, {resp, acc}} ->
        resp = update_in(resp.request.private, &Map.merge(&1, request.private))

        case stream.(data, resp, acc) do
          {:ok, resp, acc} ->
            {:cont, {request, {resp, acc}}}

          {:error, resp, exception, acc} ->
            request = put_in(request.private[:req_stream_error], exception)
            {:halt, {request, {resp, acc}}}
        end

      {:trailers, fields}, {request, {resp, acc}} ->
        fields = finch_fields_to_map(fields)
        resp = update_in(resp.trailers, &Map.merge(&1, fields))
        {:cont, {request, {resp, acc}}}
    end

    case run_stream_while(req, finch_req, finch_name, {resp, acc}, stream_fun, finch_options) do
      {:ok, request, {resp, acc}} ->
        case request.private[:req_stream_error] do
          nil ->
            case stream.(:eof, resp, acc) do
              {:ok, resp, acc} ->
                {request, put_in(resp.private[:req_stream_acc], acc)}

              {:error, resp, exception, acc} ->
                {Req.Request.put_private(resp.request, :req_stream_acc, acc), exception}
            end

          exception ->
            {Req.Request.put_private(resp.request, :req_stream_acc, acc), exception}
        end

      {:error, request, exception, {_resp, acc}} ->
        {put_in(request.private[:req_stream_acc], acc), exception}
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

  # TODO: When using finch ~> 0.22.0, convert to pattern matching
  # and revisit explicitly handling Mint errors.
  #
  # Finch >= 0.22 wraps Mint errors in its own structs. Use `is_struct/2` so
  # this still compiles against older Finch versions where these modules don't exist.
  defp normalize_error(error) when is_struct(error, Finch.TransportError) do
    %Req.TransportError{reason: error.reason}
  end

  defp normalize_error(error) when is_struct(error, Finch.HTTPError) do
    protocol = if error.module == Mint.HTTP2, do: :http2, else: :http1
    %Req.HTTPError{protocol: protocol, reason: error.reason}
  end

  defp normalize_error(error) do
    error
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

      resp = %{Req.Response.new(status: status, headers: headers, body: async) | request: req}

      case req.stream.(:eof, resp, req.private[:req_stream_acc]) do
        {:ok, resp, _acc} ->
          {req, resp}

        {:error, resp, exception, acc} ->
          {Req.Request.put_private(resp.request, :req_stream_acc, acc), exception}
      end
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

  defp run_stream_while(request, finch_req, finch_name, state, fun, finch_options) do
    case Finch.stream_while(finch_req, finch_name, {request, state}, fun, finch_options) do
      {:ok, {request, state}} ->
        {:ok, request, state}

      {:error, exception, {request, state}} ->
        {:error, request, normalize_error(exception), state}
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

  defp finch_name_options(request) do
    if request.options[:finch] && Map.has_key?(request.options, :connect_options) do
      raise ArgumentError, "cannot set both :finch and :connect_options"
    end

    custom_options? =
      Map.has_key?(request.options, :connect_options) or
        Map.has_key?(request.options, :inet6) or
        Map.has_key?(request.options, :pool_max_idle_time)

    {name, build_options, request_options, pool_options} =
      case request.options[:finch] do
        nil ->
          {nil, [], [], []}

        name when is_atom(name) ->
          IO.warn(
            "setting `:finch` to a Finch pool name is deprecated, use `finch: [name: name]` instead"
          )

          {name, [], [], []}

        options when is_list(options) ->
          {name, options} = Keyword.pop(options, :name)
          {build_options, options} = Keyword.split(options, @finch_build_options)
          {request_options, pool_options} = Keyword.split(options, @finch_request_options)
          {name, build_options, request_options, pool_options}

        other ->
          raise ArgumentError, "expected `finch: options`, got: #{inspect(other)}"
      end

    cond do
      name ->
        if pool_options != [] do
          raise ArgumentError,
                "cannot set Finch pool options together with :name in :finch, " <>
                  "configure the pool when starting #{inspect(name)} instead"
        end

        {name, build_options, request_options}

      pool_options != [] or custom_options? ->
        pool_options = Keyword.merge(pool_options(request.options), pool_options)
        name = pool_name(pool_options)

        case DynamicSupervisor.start_child(
               Req.FinchSupervisor,
               {Finch, name: name, pools: %{default: pool_options}}
             ) do
          {:ok, _} -> {name, build_options, request_options}
          {:error, {:already_started, _}} -> {name, build_options, request_options}
        end

      true ->
        {Req.Finch, build_options, request_options}
    end
  end

  @doc false
  def pool_name(pool_options) do
    hash =
      pool_options
      |> :erlang.term_to_binary()
      |> :erlang.md5()
      |> Base.encode32(padding: false)

    Module.concat(Req.FinchSupervisor, "Pool_#{hash}")
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
