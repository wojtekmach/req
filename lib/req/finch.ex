defmodule Req.Finch do
  @default_protocols [:http1]

  @moduledoc """
  Runs the request using `Finch`.

  This is the default Req _adapter_. See
  ["Adapter" section in the `Req.Request`](Req.Request.html#module-adapter) module documentation
  for more information on adapters.

  Finch returns `Mint.TransportError` exceptions on HTTP connection problems. These are automatically
  converted to `Req.TransportError` exceptions. Similarly, HTTP-protocol-related errors,
  `Mint.HTTPError` and `Finch.Error`, and converted to `Req.HTTPError`.

  ## HTTP/1 Pools

  On HTTP/1 connections, Finch creates a pool per `{scheme, host, port}` tuple. These pools
  are kept around to re-use connections as much as possible, however they are **not automatically
  terminated**. To do so, you can configure custom Finch pool:

      {:ok, _} =
        Finch.start_link(
          name: MyFinch,
          pools: %{
            default: [
              # terminate idle {scheme, host, port} pool after 60s
              pool_max_idle_time: 60_000
            ]
          }
        )

      Req.get!("https://httpbin.org/json", finch: [name: MyFinch])

  More commonly you'd add the custom Finch pool as part of your supervision tree in your
  `application.ex`:

      children = [
        {Finch,
         name: MyFinch,
         pools: %{
           default: [size: 70]
         }}
      ]

  That way you can also configure a bigger pool size for the HTTP pool. You just mustn't forget to
  pass along `finch: [name: MyFinch]` as discussed above. You could use `Req.default_options/1` to make it
  a global default but it's generally discouraged.

  For documentation about the possible pool options and their meaning, please check out the
  [Finch docs on pool configuration options](https://hexdocs.pm/finch/Finch.html#start_link/1-pool-configuration-options).

  ## Request Options

    * `:finch` - options for the Finch adapter. Defaults to a pool automatically started by
      Req. Can include:

        * `:name` - the name of the Finch pool.

        * Finch request options, e.g. `:pool_tag`, `:pool_timeout`, `:receive_timeout`. See
          `t:Finch.Request.build_opt/0` and `t:Finch.request_opt/0` for more information.

        * Finch pool options, e.g.: `:conn_max_idle_time`, `:pool_max_idle_time`, `:conn_opts`.
          See `Finch.start_link/1` for more information.

          Finch pool options cannot be mixed with `:name` option.

      Examples:

          Req.get!("https://httpbin.org/json", finch: [name: MyFinch])
          Req.get!("https://httpbin.org/json", finch: [name: MyFinch, pool_tag: :bulk])
          Req.get!("https://httpbin.org/json", finch: [conn_max_idle_time: 10_000])

    * `:connect_options` - dynamically starts (or re-uses already started) Finch pool with
      the given connection options:

        * `:timeout` - socket connect timeout in milliseconds, defaults to `30_000`.

        * `:protocols` - the HTTP protocols to use, defaults to
          `#{inspect(@default_protocols)}`.

        * `:hostname` - Mint explicit hostname, see `Mint.HTTP.connect/4` for more information.

        * `:transport_opts` - Mint transport options, see `Mint.HTTP.connect/4` for more
        information.

        * `:proxy_headers` - Mint proxy headers, see `Mint.HTTP.connect/4` for more information.

        * `:proxy` - Mint HTTP/1 proxy settings, a `{scheme, address, port, options}` tuple.
          See `Mint.HTTP.connect/4` for more information.

        * `:client_settings` - Mint HTTP/2 client settings, see `Mint.HTTP.connect/4` for more
        information.

    * `:inet6` - if set to true, uses IPv6.

      If the request URL looks like IPv6 address, i.e., say, `[::1]`, it defaults to `true`
      and otherwise defaults to `false`.
      This is a shortcut for setting `connect_options: [transport_opts: [inet6: true]]`.

    * `:receive_timeout` - socket receive timeout in milliseconds, defaults to `15_000`.

    * `:request_timeout` - response timeout in milliseconds, defaults to `:infinity`.
      See `Finch.request/3`.

    * `:unix_socket` - if set, connect through the given UNIX domain socket.

    * `:finch_private` - a map or keyword list of private metadata to add to the Finch request.
      May be useful for adding custom data when handling telemetry with `Finch.Telemetry`.

  ## Examples

  Custom `:receive_timeout`:

      iex> Req.get!(url, receive_timeout: 1000)

  Connecting through UNIX socket:

      iex> Req.get!("http:///v1.41/_ping", unix_socket: "/var/run/docker.sock").body
      "OK"

  Custom connection options:

      iex> Req.get!(url, connect_options: [timeout: 5000])

      iex> Req.get!(url, connect_options: [protocols: [:http2]])

  Connecting without certificate check (useful in development, not recommended in production):

      iex> Req.get!(url, connect_options: [transport_opts: [verify: :verify_none]])

  Connecting with custom certificates:

      iex> Req.get!(url, connect_options: [transport_opts: [cacertfile: "certs.pem"]])

  Connecting through a proxy with basic authentication:

      iex> Req.new(
      ...>  url: "https://elixir-lang.org",
      ...>  connect_options: [
      ...>    proxy: {:http, "your.proxy.com", 8888, []},
      ...>    proxy_headers: [{"proxy-authorization", "Basic " <> Base.encode64("user:pass")}]
      ...>  ]
      ...> )
      iex> |> Req.get!()

  Transport errors are represented as `Req.TransportError` exceptions:

      iex> Req.get("https://httpbin.org/delay/1", receive_timeout: 0, retry: false)
      {:error, %Req.TransportError{reason: :timeout}}

  """

  @finch_build_options [:pool_tag, :unix_socket]
  @finch_request_options [:pool_timeout, :receive_timeout, :request_timeout, :pool_strategy]

  @doc false
  def child_spec(options) do
    {name, options} = Keyword.pop!(options, :name)
    Finch.child_spec(name: name, pools: %{default: pool_options(options)})
  end

  defp build(request) do
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

    if is_function(request.body, 1) and request.options[:into] in [:self, :legacy_self] do
      raise ArgumentError, "into: :self does not support body set to req_body_fun"
    end

    request_headers = Req.Fields.get_list(request.headers)

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

    {request, finch_name, finch_request, finch_options}
  end

  @doc """
  Runs the request using `Finch`.
  """
  def run(req) do
    {req, finch_name, finch_req, finch_options} = build(req)
    run(req, finch_req, finch_name, finch_options)
  end

  defp run(req, finch_req, finch_name, finch_options) do
    case req.options[:finch_request] do
      fun when is_function(fun, 4) ->
        IO.warn("setting `:finch_request` is deprecated")
        fun.(req, finch_req, finch_name, finch_options)

      deprecated_fun when is_function(deprecated_fun, 1) ->
        IO.warn("setting `:finch_request` is deprecated")
        run_finch_request(req, deprecated_fun.(finch_req), finch_name, finch_options)

      nil ->
        case req.into do
          nil ->
            run_finch_request(req, finch_req, finch_name, finch_options)

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

    stream_fun = fn
      {:status, status}, {request, resp} ->
        {:cont, {request, %{resp | status: status}}}

      {:headers, fields}, {request, resp} ->
        resp = put_in(resp.headers, Req.Fields.new_without_normalize_with_duplicates(fields))
        {:cont, {request, resp}}

      {:data, data}, acc ->
        fun.({:data, data}, acc)

      {:trailers, fields}, {request, resp} ->
        resp = put_in(resp.trailers, Req.Fields.new_without_normalize_with_duplicates(fields))
        {:cont, {request, resp}}
    end

    case run_stream_while(req, finch_req, finch_name, resp, stream_fun, finch_options) do
      {:ok, request, response} ->
        {request, response}

      {:error, request, exception, _response} ->
        {request, exception}
    end
  end

  defp finch_stream_into_collectable(req, finch_req, finch_name, finch_options, collectable) do
    resp = Req.Response.new()

    stream_fun = fn
      {:status, 200}, {request, {nil, resp}} ->
        {acc, collector} = Collectable.into(collectable)
        {:cont, {request, {{acc, collector}, %{resp | status: 200}}}}

      {:status, status}, {request, {nil, resp}} ->
        {acc, collector} = Collectable.into("")
        {:cont, {request, {{acc, collector}, %{resp | status: status}}}}

      {:headers, fields}, {request, {collector_acc, resp}} ->
        resp = put_in(resp.headers, Req.Fields.new_without_normalize_with_duplicates(fields))
        {:cont, {request, {collector_acc, resp}}}

      {:data, data}, {request, {{acc, collector}, resp}} ->
        acc = collector.(acc, {:cont, data})
        {:cont, {request, {{acc, collector}, resp}}}

      {:trailers, fields}, {request, {collector_acc, resp}} ->
        resp = put_in(resp.trailers, Req.Fields.new_without_normalize_with_duplicates(fields))
        {:cont, {request, {collector_acc, resp}}}
    end

    case run_stream_while(req, finch_req, finch_name, {nil, resp}, stream_fun, finch_options) do
      {:ok, request, {{acc, collector}, resp}} ->
        acc = collector.(acc, :done)
        {request, %{resp | body: acc}}

      {:error, request, exception, {nil, _resp}} ->
        {request, exception}

      {:error, request, exception, {{acc, collector}, _resp}} ->
        collector.(acc, :halt)
        {request, exception}
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

  defp finch_stream_into_legacy_self(req, finch_req, finch_name, finch_options) do
    ref = Finch.async_request(finch_req, finch_name, finch_options)

    {:status, status} =
      receive do
        {^ref, message} ->
          message
      end

    headers =
      receive do
        {^ref, {:headers, headers}} ->
          headers
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

  defp run_finch_request(req, finch_request, finch_name, finch_options) do
    response_acc = {nil, [], [], []}

    response_from_acc = fn {status, headers, body, trailers} ->
      Req.Response.new(
        status: status,
        headers: headers,
        body: IO.iodata_to_binary(body),
        trailers: trailers
      )
    end

    stream_fun = fn
      {:status, value}, {request, {_, headers, body, trailers}} ->
        {:cont, {request, {value, headers, body, trailers}}}

      {:headers, value}, {request, {status, headers, body, trailers}} ->
        {:cont, {request, {status, headers ++ value, body, trailers}}}

      {:data, value}, {request, {status, headers, body, trailers}} ->
        {:cont, {request, {status, headers, [body | value], trailers}}}

      {:trailers, value}, {request, {status, headers, body, trailers}} ->
        {:cont, {request, {status, headers, body, trailers ++ value}}}
    end

    case run_stream_while(
           req,
           finch_request,
           finch_name,
           response_acc,
           stream_fun,
           finch_options
         ) do
      {:ok, request, response_acc} ->
        {request, response_from_acc.(response_acc)}

      {:error, request, exception, _response_acc} ->
        {request, exception}
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
          @default_protocols
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
