defmodule Req.Steps do
  @moduledoc """
  The collection of built-in steps.

  Req is composed of three main pieces:

    * `Req` - the high-level API

    * `Req.Request` - the low-level API and the request struct

    * `Req.Steps` - the collection of built-in steps (you're here!)
  """

  require Logger

  ## Request steps

  @doc """
  Sets base URL for all requests.

  ## Request Options

    * `:base_url` - if set, the request URL is merged with this base URL.

  ## Examples

      iex> req = Req.new(base_url: "https://httpbin.org")
      iex> Req.get!(req, url: "/status/200").status
      200
      iex> Req.get!(req, url: "/status/201").status
      201

  """
  @doc step: :request
  def put_base_url(request)

  def put_base_url(%{options: %{base_url: base_url}} = request) do
    if request.url.scheme != nil do
      request
    else
      %{request | url: URI.parse(join(base_url, request.url))}
    end
  end

  def put_base_url(request) do
    request
  end

  defp join(base, url) do
    case {:binary.last(base), to_string(url)} do
      {?/, "/" <> rest} -> base <> rest
      {?/, rest} -> base <> rest
      {_, ""} -> base
      {_, "/" <> rest} -> base <> "/" <> rest
      {_, rest} -> base <> "/" <> rest
    end
  end

  @doc """
  Sets request authentication.

  ## Request Options

    * `:auth` - sets the `authorization` header:

        * `string` - sets to this value;

        * `{username, password}` - uses Basic HTTP authentication;

        * `{:bearer, token}` - uses Bearer HTTP authentication;

        * `:netrc` - load credentials from `.netrc` at path specified in `NETRC` environment variable.
          If `NETRC` is not set, load `.netrc` in user's home directory;

        * `{:netrc, path}` - load credentials from `path`

  ## Examples

      iex> Req.get!("https://httpbin.org/basic-auth/foo/bar", auth: {"bad", "bad"}).status
      401
      iex> Req.get!("https://httpbin.org/basic-auth/foo/bar", auth: {"foo", "bar"}).status
      200

      iex> Req.get!("https://httpbin.org/bearer", auth: {:bearer, ""}).status
      401
      iex> Req.get!("https://httpbin.org/bearer", auth: {:bearer, "foo"}).status
      200

      iex> System.put_env("NETRC", "./test/my_netrc")
      iex> Req.get!("https://httpbin.org/basic-auth/foo/bar", auth: :netrc).status
      200

      iex> Req.get!("https://httpbin.org/basic-auth/foo/bar", auth: {:netrc, "./test/my_netrc"}).status
      200
  """
  @doc step: :request
  def auth(request) do
    auth(request, request.options[:auth])
  end

  defp auth(request, nil) do
    request
  end

  defp auth(request, authorization) when is_binary(authorization) do
    Req.Request.put_new_header(request, "authorization", authorization)
  end

  defp auth(request, {:bearer, token}) when is_binary(token) do
    Req.Request.put_new_header(request, "authorization", "Bearer #{token}")
  end

  defp auth(request, {username, password}) when is_binary(username) and is_binary(password) do
    value = Base.encode64("#{username}:#{password}")
    Req.Request.put_new_header(request, "authorization", "Basic #{value}")
  end

  defp auth(request, :netrc) do
    path = System.get_env("NETRC") || Path.join(System.user_home!(), ".netrc")
    authenticate_with_netrc(request, path)
  end

  defp auth(request, {:netrc, path}) do
    authenticate_with_netrc(request, path)
  end

  defp authenticate_with_netrc(request, path) when is_binary(path) do
    case Map.fetch(load_netrc(path), request.url.host) do
      {:ok, {username, password}} ->
        auth(request, {username, password})

      :error ->
        request
    end
  end

  defp load_netrc(path) do
    case File.read(path) do
      {:ok, ""} ->
        raise ".netrc file is empty"

      {:ok, contents} ->
        contents
        |> String.trim()
        |> String.split()
        |> parse_netrc()

      {:error, reason} ->
        raise "error reading .netrc file: #{:file.format_error(reason)}"
    end
  end

  defp parse_netrc(credentials), do: parse_netrc(credentials, %{})

  defp parse_netrc([], acc), do: acc

  defp parse_netrc([_, machine, _, login, _, password | tail], acc) do
    acc = Map.put(acc, String.trim(machine), {String.trim(login), String.trim(password)})
    parse_netrc(tail, acc)
  end

  defp parse_netrc(_, _), do: raise("error parsing .netrc file")

  @user_agent "req/#{Mix.Project.config()[:version]}"

  @doc """
  Sets the user-agent header.

  ## Request Options

    * `:user_agent` - sets the `user-agent` header. Defaults to `"#{@user_agent}"`.

  ## Examples

      iex> Req.get!("https://httpbin.org/user-agent").body
      %{"user-agent" => "#{@user_agent}"}

      iex> Req.get!("https://httpbin.org/user-agent", user_agent: "foo").body
      %{"user-agent" => "foo"}
  """
  @doc step: :request
  def put_user_agent(request) do
    user_agent = Req.Request.get_option(request, :user_agent, @user_agent)
    Req.Request.put_new_header(request, "user-agent", user_agent)
  end

  @doc """
  Asks the server to return compressed response.

  Supported formats:

    * `gzip`
    * `br` (if [brotli] is installed)
    * `zstd` (if [ezstd] is installed)

  ## Request Options

    * `:compressed` - if set to `true`, sets the `accept-encoding` header with compression
      algorithms that Req supports. Defaults to `true`.

  ## Examples

  Req automatically decompresses response body (`decompress_body/1` step) so let's disable that by
  passing `raw: true`.

  By default, we ask the server to send compressed response. Let's look at the headers and the raw
  body. Notice the body starts with `<<31, 139>>` (`<<0x1F, 0x8B>>`), the "magic bytes" for gzip:

      iex> response = Req.get!("https://elixir-lang.org", raw: true)
      iex> Req.Response.get_header(response, "content-encoding")
      ["gzip"]
      iex> response.body |> binary_part(0, 2)
      <<31, 139>>

  Now, let's pass `compressed: false` and notice the raw body was not compressed:

      iex> response = Req.get!("https://elixir-lang.org", raw: true, compressed: false)
      iex> Req.Response.get_header(response, "content-encoding")
      nil
      iex> response.body |> binary_part(0, 15)
      "<!DOCTYPE html>"

  The Brotli and Zstandard compression algorithms are also supported if the optional
  packages are installed:

      Mix.install([
        :req,
        {:brotli, "~> 0.3.0"},
        {:ezstd, "~> 1.0"}
      ])

      response = Req.get!("https://httpbin.org/anything")
      response.body["headers"]["Accept-Encoding"]
      #=> "zstd, br, gzip"

  [brotli]: https://hex.pm/packages/brotli
  [ezstd]: https://hex.pm/packages/ezstd
  """
  @doc step: :request
  def compressed(request) do
    case Req.Request.get_option(request, :compressed, true) do
      true ->
        Req.Request.put_new_header(request, "accept-encoding", supported_accept_encoding())

      false ->
        request
    end
  end

  defmacrop brotli_loaded? do
    if Code.ensure_loaded?(:brotli) do
      true
    else
      quote do
        Code.ensure_loaded?(:brotli)
      end
    end
  end

  defmacrop ezstd_loaded? do
    if Code.ensure_loaded?(:ezstd) do
      true
    else
      quote do
        Code.ensure_loaded?(:ezstd)
      end
    end
  end

  defp supported_accept_encoding do
    value = "gzip"
    value = if brotli_loaded?(), do: "br, " <> value, else: value
    if ezstd_loaded?(), do: "zstd, " <> value, else: value
  end

  @doc """
  Encodes the request body.

  ## Request Options

    * `:form` - if set, encodes the request body as form data (using `URI.encode_query/1`).

    * `:json` - if set, encodes the request body as JSON (using `Jason.encode_to_iodata!/1`), sets
      the `accept` header to `application/json`, and the `content-type` header to `application/json`.

  ## Examples

      iex> Req.post!("https://httpbin.org/anything", form: [x: 1]).body["form"]
      %{"x" => "1"}

      iex> Req.post!("https://httpbin.org/post", json: %{x: 2}).body["json"]
      %{"x" => 2}

  """
  @doc step: :request
  def encode_body(request) do
    cond do
      data = request.options[:form] ->
        %{request | body: URI.encode_query(data)}
        |> Req.Request.put_new_header("content-type", "application/x-www-form-urlencoded")

      data = request.options[:json] ->
        %{request | body: Jason.encode_to_iodata!(data)}
        |> Req.Request.put_new_header("content-type", "application/json")
        |> Req.Request.put_new_header("accept", "application/json")

      true ->
        request
    end
  end

  @doc """
  Uses a templated request path.

  ## Request Options

    * `:path_params` - params to add to the templated path. Defaults to `[]`.

  ## Examples

      iex> Req.get!("https://httpbin.org/status/:code", path_params: [code: 200]).status
      200

  """
  @doc step: :request
  def put_path_params(request) do
    put_path_params(request, Req.Request.get_option(request, :path_params, []))
  end

  defp put_path_params(request, []) do
    request
  end

  defp put_path_params(request, params) do
    request
    |> Req.Request.put_private(:path_params_template, request.url.path)
    |> apply_path_params(params)
  end

  defp apply_path_params(request, params) do
    update_in(request.url.path, fn
      nil ->
        nil

      path ->
        Regex.replace(~r/:([a-zA-Z]{1}[\w_]*)/, path, fn match, key ->
          case params[String.to_existing_atom(key)] do
            nil ->
              match

            value ->
              value |> to_string() |> URI.encode()
          end
        end)
    end)
  end

  @doc """
  Adds params to request query string.

  ## Request Options

    * `:params` - params to add to the request query string. Defaults to `[]`.

  ## Examples

      iex> Req.get!("https://httpbin.org/anything/query", params: [x: 1, y: 2]).body["args"]
      %{"x" => "1", "y" => "2"}

  """
  @doc step: :request
  def put_params(request) do
    put_params(request, Req.Request.get_option(request, :params, []))
  end

  defp put_params(request, []) do
    request
  end

  defp put_params(request, params) do
    encoded = URI.encode_query(params)

    update_in(request.url.query, fn
      nil -> encoded
      query -> query <> "&" <> encoded
    end)
  end

  @doc """
  Sets the "Range" request header.

  ## Request Options

    * `:range` - can be one of the following:

        * a string - returned as is

        * a `first..last` range - converted to `"bytes=<first>-<last>"`

  ## Examples

      iex> response = Req.get!("https://httpbin.org/range/100", range: 0..3)
      iex> response.status
      206
      iex> response.body
      "abcd"
      iex> Req.Response.get_header(response, "content-range")
      ["bytes 0-3/100"]
  """
  @doc step: :request
  def put_range(%{options: %{range: range}} = request) when is_binary(range) do
    Req.Request.put_header(request, "range", range)
  end

  def put_range(%{options: %{range: first..last}} = request) do
    Req.Request.put_header(request, "range", "bytes=#{first}-#{last}")
  end

  def put_range(request) do
    request
  end

  @doc """
  Performs HTTP caching using `if-modified-since` header.

  Only successful (200 OK) responses are cached.

  This step also _prepends_ a response step that loads and writes the cache. Be careful when
  _prepending_ other response steps, make sure the cache is loaded/written as soon as possible.

  ## Options

    * `:cache` - if `true`, performs simple caching using `if-modified-since` header. Defaults to `false`.

    * `:cache_dir` - the directory to store the cache, defaults to `<user_cache_dir>/req`
      (see: `:filename.basedir/3`)

  ## Examples

      iex> url = "https://elixir-lang.org"
      iex> response1 = Req.get!(url, cache: true)
      iex> response2 = Req.get!(url, cache: true)
      iex> response1 == response2
      true

  """
  @doc step: :request
  def cache(request) do
    case request.options[:cache] do
      true ->
        dir = request.options[:cache_dir] || :filename.basedir(:user_cache, ~c"req")
        cache_path = cache_path(dir, request)

        request
        |> put_if_modified_since(cache_path)
        |> Req.Request.prepend_response_steps(handle_cache: &handle_cache(&1, cache_path))

      other when other in [false, nil] ->
        request
    end
  end

  defp put_if_modified_since(request, cache_path) do
    case File.stat(cache_path) do
      {:ok, stat} ->
        http_datetime_string =
          stat.mtime
          |> NaiveDateTime.from_erl!()
          |> DateTime.from_naive!("Etc/UTC")
          |> format_http_datetime()

        Req.Request.put_new_header(request, "if-modified-since", http_datetime_string)

      _ ->
        request
    end
  end

  defp handle_cache({request, response}, cache_path) do
    cond do
      response.status == 200 ->
        write_cache(cache_path, response)
        {request, response}

      response.status == 304 ->
        response = load_cache(cache_path)
        {request, response}

      true ->
        {request, response}
    end
  end

  @doc """
  Compresses the request body.

  ## Request Options

    * `:compress_body` - if set to `true`, compresses the request body using gzip.
      Defaults to `false`.

  """
  @doc step: :request
  def compress_body(request) do
    if request.options[:compress_body] do
      body =
        case request.body do
          iodata when is_binary(iodata) or is_list(iodata) ->
            :zlib.gzip(iodata)

          enumerable ->
            gzip_stream(enumerable)
        end

      request
      |> Map.replace!(:body, body)
      |> Req.Request.put_header("content-encoding", "gzip")
    else
      request
    end
  end

  defp gzip_stream(enumerable) do
    eof = make_ref()

    enumerable
    |> Stream.concat([eof])
    |> Stream.transform(
      fn ->
        z = :zlib.open()
        # https://github.com/erlang/otp/blob/OTP-26.0/erts/preloaded/src/zlib.erl#L551
        :ok = :zlib.deflateInit(z, :default, :deflated, 16 + 15, 8, :default)
        z
      end,
      fn
        ^eof, z ->
          buf = :zlib.deflate(z, [], :finish)
          {buf, z}

        data, z ->
          buf = :zlib.deflate(z, data)
          {buf, z}
      end,
      fn z ->
        :ok = :zlib.deflateEnd(z)
        :ok = :zlib.close(z)
      end
    )
  end

  @doc """
  Runs the request using `Finch`.

  This is the default Req _adapter_. See
  ["Adapter" section in the `Req.Request`](Req.Request.html#module-adapter) module
  documentation for more information on adapters.

  ## Request Options

    * `:finch` - the name of the Finch pool. Defaults to a pool automatically started by
      Req. The default pool uses HTTP/1 although that may change in the future.

    * `:connect_options` - dynamically starts (or re-uses already started) Finch pool with
      the given connection options:

        * `:timeout` - socket connect timeout in milliseconds, defaults to `30_000`.

        * `:protocol` - the HTTP protocol to use, defaults to `:http1`.

        * `:hostname` - Mint explicit hostname, see `Mint.HTTP.connect/4` for more information.

        * `:transport_opts` - Mint transport options, see `Mint.HTTP.connect/4` for more information.

        * `:proxy_headers` - Mint proxy headers, see `Mint.HTTP.connect/4` for more information.

        * `:proxy` - Mint HTTP/1 proxy settings, a `{schema, address, port, options}` tuple.
          See `Mint.HTTP.connect/4` for more information.

        * `:client_settings` - Mint HTTP/2 client settings, see `Mint.HTTP.connect/4` for more information.

    * `:inet6` - if set to true, uses IPv6. Defaults to `false`. This is a shortcut for
      setting `connect_options: [transport_opts: [inet6: true]]`.

    * `:pool_timeout` - pool checkout timeout in milliseconds, defaults to `5000`.

    * `:receive_timeout` - socket receive timeout in milliseconds, defaults to `15_000`.

    * `:unix_socket` - if set, connect through the given UNIX domain socket.

    * `:finch_request` - a function that executes the Finch request, defaults to using `Finch.request/3`.

      The function should accept 4 arguments:

        * `request` - the `%Req.Request{}` struct

        * `finch_request` - the Finch request

        * `finch_name` - the Finch name

        * `finch_options` - the Finch options

      And it should return either `{request, response}` or `{request, exception}`.

  ## Examples

  Custom `:receive_timeout`:

      iex> Req.get!(url, receive_timeout: 1000)

  Connecting through UNIX socket:

      iex> Req.get!("http:///v1.41/_ping", unix_socket: "/var/run/docker.sock").body
      "OK"

  Connecting with custom connection options:

      iex> Req.get!(url, connect_options: [timeout: 5000])

      iex> Req.get!(url, connect_options: [protocol: :http2])

  Connecting with built-in CA store (requires OTP 25+):

      iex> Req.get!(url, connect_options: [transport_opts: [cacerts: :public_key.cacerts_get()]])

  Stream response body using `Finch.stream/5`:

      fun = fn request, finch_request, finch_name, finch_options ->
        fun = fn
          {:status, status}, response ->
            %{response | status: status}

          {:headers, headers}, response ->
            %{response | headers: headers}

          {:data, data}, response ->
            IO.puts(data)
            response
        end

        case Finch.stream(finch_request, finch_name, Req.Response.new(), fun, finch_options) do
          {:ok, response} -> {request, response}
          {:error, exception} -> {request, exception}
        end
      end

      Req.get!("https://httpbin.org/stream/10", finch_request: fun)

  """
  @doc step: :request
  def run_finch(request) do
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

    finch_options =
      request.options |> Map.take([:receive_timeout, :pool_timeout]) |> Enum.to_list()

    run_finch(request, finch_request, finch_name, finch_options)
  end

  defp run_finch(req, finch_req, finch_name, finch_options) do
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

          :self ->
            finch_stream_into_self(req, finch_req, finch_name, finch_options)

          collectable when collectable != :self ->
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
        fields = finch_fields_to_map(fields)
        resp = update_in(resp.headers, &Map.merge(&1, fields))
        {:cont, {req, resp}}

      {:data, data}, acc ->
        fun.({:data, data}, acc)

      {:trailers, fields}, {req, resp} ->
        fields = finch_fields_to_map(fields)
        resp = update_in(resp.trailers, &Map.merge(&1, fields))
        {:cont, {req, resp}}
    end

    case finch_stream_while(finch_req, finch_name, {req, resp}, fun, finch_options) do
      {:ok, acc} ->
        acc

      {:error, exception} ->
        {req, exception}
    end
  end

  defp finch_stream_into_collectable(req, finch_req, finch_name, finch_options, collectable) do
    {acc, collector} = Collectable.into(collectable)
    resp = Req.Response.new()

    fun = fn
      {:status, status}, {acc, req, resp} ->
        {acc, req, %{resp | status: status}}

      {:headers, fields}, {acc, req, resp} ->
        fields = finch_fields_to_map(fields)
        resp = update_in(resp.headers, &Map.merge(&1, fields))
        {acc, req, resp}

      {:data, data}, {acc, req, resp} ->
        acc = collector.(acc, {:cont, data})
        {acc, req, resp}

      {:trailers, fields}, {acc, req, resp} ->
        fields = finch_fields_to_map(fields)
        resp = update_in(resp.trailers, &Map.merge(&1, fields))
        {acc, req, resp}
    end

    case Finch.stream(finch_req, finch_name, {acc, req, resp}, fun, finch_options) do
      {:ok, {acc, req, resp}} ->
        acc = collector.(acc, :done)
        {req, %{resp | body: acc}}

      {:error, exception} ->
        {req, exception}
    end
  end

  # TODO: WIP
  defp finch_stream_into_self(req, finch_req, finch_name, finch_options) do
    ref = Finch.async_request(finch_req, finch_name, finch_options)

    {:status, status} =
      receive do
        {^ref, message} ->
          message
      end

    headers =
      receive do
        {^ref, message} ->
          # TODO: handle trailers
          {:headers, headers} = message

          Enum.reduce(headers, %{}, fn {name, value}, acc ->
            Map.update(acc, name, [value], &(&1 ++ [value]))
          end)
      end

    async = %Req.Async{
      ref: ref,
      stream_fun: &finch_parse_message/2,
      cancel_fun: &finch_cancel/1
    }

    req = put_in(req.async, async)
    resp = Req.Response.new(status: status, headers: headers)
    {req, resp}
  end

  # TODO: Remove on Finch 0.17
  if Code.ensure_loaded?(Finch) and function_exported?(Finch, :stream_while, 5) do
    defp finch_stream_while(finch_req, finch_name, acc, fun, finch_options) do
      Finch.stream_while(finch_req, finch_name, acc, fun, finch_options)
    end
  else
    defp finch_stream_while(finch_req, finch_name, acc, fun, finch_options) do
      fun = fn item, acc ->
        case fun.(item, acc) do
          {:cont, acc} ->
            acc

          {:halt, _acc} ->
            raise ArgumentError, "returning {:halt, _acc} requires Finch 0.17+"

          other ->
            raise ArgumentError, "expected {:cont, _acc}, got: #{inspect(other)}"
        end
      end

      Finch.stream(finch_req, finch_name, acc, fun, finch_options)
    end
  end

  defp run_finch_request(finch_request, finch_name, finch_options) do
    case Finch.request(finch_request, finch_name, finch_options) do
      {:ok, response} -> Req.Response.new(response)
      {:error, exception} -> exception
    end
  end

  defp finch_fields_to_map(fields) do
    Enum.reduce(fields, %{}, fn {name, value}, acc ->
      Map.update(acc, name, [value], &(&1 ++ [value]))
    end)
  end

  defp finch_parse_message(ref, {ref, {:data, data}}) do
    {:ok, [{:data, data}]}
  end

  defp finch_parse_message(ref, {ref, :done}) do
    {:ok, [:done]}
  end

  # TODO: handle remaining possible Finch results
  defp finch_parse_message(_ref, _other) do
    :unknown
  end

  defp finch_cancel(ref) do
    Finch.cancel_async_request(ref)
  end

  defp finch_name(request) do
    if name = request.options[:finch] do
      if request.options[:connect_options] do
        raise ArgumentError, "cannot set both :finch and :connect_options"
      end

      name
    else
      connect_options = request.options[:connect_options] || []
      inet6_options = if request.options[:inet6], do: [inet6: true], else: []

      if connect_options != [] || inet6_options != [] do
        Req.Request.validate_options(
          connect_options,
          MapSet.new([
            :timeout,
            :protocol,
            :transport_opts,
            :proxy_headers,
            :proxy,
            :client_settings,
            :hostname
          ])
        )

        hostname_opts = Keyword.take(connect_options, [:hostname])

        transport_opts = [
          transport_opts:
            Keyword.merge(
              Keyword.take(connect_options, [:timeout]) ++ inet6_options,
              Keyword.get(connect_options, :transport_opts, [])
            )
        ]

        proxy_headers_opts = Keyword.take(connect_options, [:proxy_headers])
        proxy_opts = Keyword.take(connect_options, [:proxy])
        client_settings_opts = Keyword.take(connect_options, [:client_settings])

        pool_opts = [
          conn_opts:
            hostname_opts ++
              transport_opts ++
              proxy_headers_opts ++
              proxy_opts ++
              client_settings_opts,
          protocol: connect_options[:protocol] || :http1
        ]

        name =
          [connect_options, inet6_options]
          |> :erlang.term_to_binary()
          |> :erlang.md5()
          |> Base.url_encode64(padding: false)

        name = Module.concat(Req.FinchSupervisor, "Pool_#{name}")

        case DynamicSupervisor.start_child(
               Req.FinchSupervisor,
               {Finch, name: name, pools: %{default: pool_opts}}
             ) do
          {:ok, _} ->
            name

          {:error, {:already_started, _}} ->
            name
        end
      else
        Req.Finch
      end
    end
  end

  @doc """
  Runs the request against a plug instead of over the network.

  ## Request Options

    * `:plug` - if set, the plug to run the request against.

  ## Examples

  This step is particularly useful to test plugs:

      defmodule Echo do
        def call(conn, _) do
          "/" <> path = conn.request_path
          Plug.Conn.send_resp(conn, 200, path)
        end
      end

      test "echo" do
        assert Req.get!("http:///hello", plug: Echo).body == "hello"
      end

  You can define plugs as functions too:

      test "echo" do
        echo = fn conn ->
          "/" <> path = conn.request_path
          Plug.Conn.send_resp(conn, 200, path)
        end

        assert Req.get!("http:///hello", plug: echo).body == "hello"
      end

  which is particularly useful to create HTTP service mocks with tools like
  [Bypass](https://github.com/PSPDFKit-labs/bypass).

  Here is another example, let's run the request against `Plug.Static` pointed to the Req's source
  code and fetch the README:

      iex> resp = Req.get!("http:///README.md", plug: {Plug.Static, at: "/", from: "."})
      iex> resp.body =~ "Req is a batteries-included HTTP client for Elixir."
      true
  """
  @doc step: :request
  def put_plug(request) do
    if request.options[:plug] do
      %{request | adapter: &run_plug/1}
    else
      request
    end
  end

  defp run_plug(request) do
    req_body =
      case request.body do
        iodata when is_binary(iodata) or is_list(iodata) ->
          IO.iodata_to_binary(iodata)

        nil ->
          ""

        enumerable ->
          enumerable |> Enum.to_list() |> IO.iodata_to_binary()
      end

    req_headers =
      if unquote(Req.MixProject.legacy_headers_as_lists?()) do
        request.headers
      else
        for {name, values} <- request.headers,
            value <- values do
          {name, value}
        end
      end

    conn =
      Plug.Test.conn(request.method, request.url, req_body)
      |> Map.replace!(:req_headers, req_headers)
      |> call_plug(request.options[:plug])

    response =
      Req.Response.new(
        status: conn.status,
        headers: conn.resp_headers,
        body: conn.resp_body
      )

    {request, response}
  end

  defp call_plug(conn, plug) when is_atom(plug) do
    plug.call(conn, [])
  end

  defp call_plug(conn, {plug, options}) when is_atom(plug) do
    plug.call(conn, plug.init(options))
  end

  defp call_plug(conn, plug) when is_function(plug, 1) do
    plug.(conn)
  end

  ## Response steps

  @doc """
  Decompresses the response body based on the `content-encoding` header.

  This step is disabled on response body streaming. If response body is not a binary, in other
  words it has been transformed by another step, it is left as is.

  Supported formats:

  | Format        | Decoder                                         |
  | ------------- | ----------------------------------------------- |
  | gzip, x-gzip  | `:zlib.gunzip/1`                                |
  | br            | `:brotli.decode/1` (if [brotli] is installed)   |
  | zstd          | `:ezstd.decompress/1` (if [ezstd] is installed) |
  | _other_       | Returns data as is                              |

  This step updates the following headers to reflect the changes:

    * `content-length` is set to the length of the decompressed body
    * `content-encoding` is removed

  ## Options

    * `:raw` - if set to `true`, disables response body decompression. Defaults to `false`.

  ## Examples

      iex> response = Req.get!("https://httpbin.org/gzip")
      iex> Req.Response.get_header(response, "content-encoding")
      ["gzip"]
      iex> response.body["gzipped"]
      true

  If the [brotli] package is installed, Brotli is also supported:

      Mix.install([
        :req,
        {:brotli, "~> 0.3.0"}
      ])

      response = Req.get!("https://httpbin.org/brotli")
      Req.Response.get_header(response, "content-encoding")
      #=> ["br"]
      response.body["brotli"]
      #=> true

  [brotli]: http://hex.pm/packages/brotli
  [ezstd]: https://hex.pm/packages/ezstd
  """
  @doc step: :response
  def decompress_body(request_response)

  def decompress_body({request, %{body: body} = response})
      when request.into != nil or
             body == "" or
             not is_binary(body) do
    {request, response}
  end

  def decompress_body({request, response}) do
    if request.options[:raw] do
      {request, response}
    else
      codecs = compression_algorithms(Req.Response.get_header(response, "content-encoding"))
      {decompressed_body, unknown_codecs} = decompress_body(codecs, response.body, [])
      decompressed_content_length = decompressed_body |> byte_size() |> to_string()

      response =
        %Req.Response{response | body: decompressed_body}
        |> Req.Response.put_header("content-length", decompressed_content_length)

      response =
        if unknown_codecs == [] do
          Req.Response.delete_header(response, "content-encoding")
        else
          Req.Response.put_header(response, "content-encoding", Enum.join(unknown_codecs, ", "))
        end

      {request, response}
    end
  end

  defp decompress_body([gzip | rest], body, acc) when gzip in ["gzip", "x-gzip"] do
    decompress_body(rest, :zlib.gunzip(body), acc)
  end

  defp decompress_body(["br" | rest], body, acc) do
    if brotli_loaded?() do
      {:ok, decompressed} = :brotli.decode(body)
      decompress_body(rest, decompressed, acc)
    else
      Logger.debug(":brotli library not loaded, skipping brotli decompression")
      decompress_body(rest, body, ["br" | acc])
    end
  end

  defp decompress_body(["zstd" | rest], body, acc) do
    if ezstd_loaded?() do
      decompress_body(rest, :ezstd.decompress(body), acc)
    else
      Logger.debug(":ezstd library not loaded, skipping zstd decompression")
      decompress_body(rest, body, ["zstd" | acc])
    end
  end

  defp decompress_body(["identity" | rest], body, acc) do
    decompress_body(rest, body, acc)
  end

  defp decompress_body([codec | rest], body, acc) do
    Logger.debug("algorithm #{inspect(codec)} is not supported")
    decompress_body(rest, body, [codec | acc])
  end

  defp decompress_body([], body, acc) do
    {body, acc}
  end

  defp compression_algorithms(values) do
    values
    |> Enum.flat_map(fn value ->
      value
      |> String.downcase()
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
    end)
    |> Enum.reverse()
  end

  defmacrop nimble_csv_loaded? do
    if Code.ensure_loaded?(NimbleCSV) do
      true
    else
      quote do
        Code.ensure_loaded?(NimbleCSV)
      end
    end
  end

  @doc false
  def output(request_response)

  def output({request, response}) do
    output({request, response}, request.options[:output])
  end

  defp output(request_response, nil) do
    request_response
  end

  defp output({request, response}, :remote_name) do
    path = Path.basename(request.url.path || "")
    output({request, response}, path)
  end

  defp output(_request_response, "") do
    raise "cannot write to file \"\""
  end

  defp output({request, response}, path) do
    File.write!(path, response.body)
    response = %{response | body: ""}
    {request, response}
  end

  @doc """
  Decodes response body based on the detected format.

  Supported formats:

  | Format   | Decoder                                                           |
  | -------- | ----------------------------------------------------------------- |
  | json     | `Jason.decode!/2`                                                 |
  | gzip     | `:zlib.gunzip/1`                                                  |
  | tar, tgz | `:erl_tar.extract/2`                                              |
  | zip      | `:zip.unzip/2`                                                    |
  | csv      | `NimbleCSV.RFC4180.parse_string/2` (if [nimble_csv] is installed) |

  This step is disabled on response body streaming. If response body is not a binary, in other
  words it has been transformed by another step, it is left as is.

  ## Request Options

    * `:decode_body` - if set to `false`, disables automatic response body decoding.
      Defaults to `true`.

    * `:decode_json` - options to pass to `Jason.decode!/2`, defaults to `[]`.

    * `:raw` - if set to `true`, disables response body decoding. Defaults to `false`.

  ## Examples

  Decode JSON:

      iex> response = Req.get!("https://httpbin.org/json")
      ...> response.body["slideshow"]["title"]
      "Sample Slide Show"

  Decode gzip:

      iex> response = Req.get!("https://httpbin.org/gzip")
      ...> response.body["gzipped"]
      true

  [nimble_csv]: https://hex.pm/packages/nimble_csv
  """
  @doc step: :response
  def decode_body(request_response)

  def decode_body({request, %{body: body} = response})
      when request.async != nil or
             body == "" or
             not is_binary(body) do
    {request, response}
  end

  def decode_body({request, response}) do
    # TODO: remove on Req 1.0
    output? = request.options[:output] not in [nil, false]

    if request.options[:raw] == true or
         request.options[:decode_body] == false or
         output? or
         Req.Response.get_header(response, "content-encoding") != [] do
      {request, response}
    else
      decode_body({request, response}, format(request, response))
    end
  end

  defp decode_body({request, response}, format) when format in ~w(json json-api) do
    options = Req.Request.get_option(request, :decode_json, [])
    {request, update_in(response.body, &Jason.decode!(&1, options))}
  end

  defp decode_body({request, response}, "gz") do
    {request, update_in(response.body, &:zlib.gunzip/1)}
  end

  defp decode_body({request, response}, "tar") do
    {:ok, files} = :erl_tar.extract({:binary, response.body}, [:memory])
    {request, put_in(response.body, files)}
  end

  defp decode_body({request, response}, "tgz") do
    {:ok, files} = :erl_tar.extract({:binary, response.body}, [:memory, :compressed])
    {request, put_in(response.body, files)}
  end

  defp decode_body({request, response}, "zip") do
    {:ok, files} = :zip.extract(response.body, [:memory])
    {request, put_in(response.body, files)}
  end

  defp decode_body({request, response}, "csv") do
    if nimble_csv_loaded?() do
      options = [skip_headers: false]
      {request, update_in(response.body, &NimbleCSV.RFC4180.parse_string(&1, options))}
    else
      {request, response}
    end
  end

  defp decode_body({request, response}, _format) do
    {request, response}
  end

  defp format(request, response) do
    case Req.Response.get_header(response, "content-type") do
      [content_type] ->
        # TODO: remove ` || ` when we require Elixir v1.13
        path = request.url.path || ""

        case extensions(content_type, path) do
          [ext | _] -> ext
          [] -> nil
        end

      [] ->
        []
    end
  end

  defp extensions("application/octet-stream", path) do
    if tgz?(path) do
      ["tgz"]
    else
      path |> MIME.from_path() |> MIME.extensions()
    end
  end

  defp extensions("application/" <> subtype, path) when subtype in ~w(gzip x-gzip) do
    if tgz?(path) do
      ["tgz"]
    else
      ["gz"]
    end
  end

  defp extensions(content_type, _path) do
    MIME.extensions(content_type)
  end

  defp tgz?(path) do
    case Path.extname(path) do
      ".tgz" -> true
      ".gz" -> String.ends_with?(path, ".tar.gz")
      _ -> false
    end
  end

  @doc """
  Follows redirects.

  The original request method may be changed to GET depending on the status code:

  | Code          | Method handling    |
  | ------------- | ------------------ |
  | 301, 302, 303 | Changed to GET     |
  | 307, 308      | Method not changed |

  ## Request Options

    * `:redirect` - if set to `false`, disables automatic response redirects.
      Defaults to `true`.

    * `:redirect_trusted` - by default, authorization credentials are only sent
      on redirects with the same host, scheme and port. If `:redirect_trusted` is set
      to `true`, credentials will be sent to any host.

    * `:redirect_log_level` - the log level to emit redirect logs at. Can also be set
      to `false` to disable logging these messsages. Defaults to `:debug`.

    * `:max_redirects` - the maximum number of redirects, defaults to `10`.
      If the limit is reached, an error is raised.

  ## Examples

      iex> Req.get!("http://api.github.com").status
      # 23:24:11.670 [debug] redirecting to https://api.github.com/
      200

      iex> Req.get!("https://httpbin.org/redirect/4", max_redirects: 3)
      # 23:07:59.570 [debug] redirecting to /relative-redirect/3
      # 23:08:00.068 [debug] redirecting to /relative-redirect/2
      # 23:08:00.206 [debug] redirecting to /relative-redirect/1
      ** (RuntimeError) too many redirects (3)

      iex> Req.get!("http://api.github.com", redirect_log_level: false)
      200

      iex> Req.get!("http://api.github.com", redirect_log_level: :error)
      # 23:24:11.670 [error]  redirecting to https://api.github.com/
      200

  """
  @doc step: :response
  def redirect(request_response)

  def redirect({request, response}) do
    redirect? =
      case Req.Request.fetch_option(request, :follow_redirects) do
        {:ok, redirect?} ->
          IO.warn(":follow_redirects option has been renamed to :redirect")
          redirect?

        :error ->
          Req.Request.get_option(request, :redirect, true)
      end

    cond do
      !redirect? ->
        {request, response}

      response.status in [301, 302, 303, 307, 308] ->
        max_redirects = Req.Request.get_option(request, :max_redirects, 10)
        redirect_count = Req.Request.get_private(request, :req_redirect_count, 0)

        if redirect_count < max_redirects do
          request =
            request
            |> build_redirect_request(response)
            |> Req.Request.put_private(:req_redirect_count, redirect_count + 1)

          {_, result} = Req.Request.run(request)
          {Req.Request.halt(request), result}
        else
          raise "too many redirects (#{max_redirects})"
        end

      true ->
        {request, response}
    end
  end

  defp build_redirect_request(request, response) do
    [location] = Req.Response.get_header(response, "location")

    log_level = Req.Request.get_option(request, :redirect_log_level, :debug)
    log_redirect(log_level, location)

    redirect_trusted =
      case Req.Request.fetch_option(request, :location_trusted) do
        {:ok, trusted} ->
          IO.warn(":location_trusted option has been renamed to :redirect_trusted")
          trusted

        :error ->
          request.options[:redirect_trusted]
      end

    location_url = URI.merge(request.url, URI.parse(location))

    request
    # assume put_params step already run so remove :params option so it's not applied again
    |> Req.Request.delete_option(:params)
    |> remove_credentials_if_untrusted(redirect_trusted, location_url)
    |> put_redirect_method(response.status)
    |> Map.replace!(:url, location_url)
  end

  defp log_redirect(false, _location), do: :ok

  defp log_redirect(level, location) do
    Logger.log(level, ["redirecting to ", location])
  end

  # https://www.rfc-editor.org/rfc/rfc9110#name-301-moved-permanently and 302:
  #
  # > Note: For historical reasons, a user agent MAY change the request method from
  # > POST to GET for the subsequent request.
  #
  # And my understanding is essentially same applies for 303.
  # Also see https://everything.curl.dev/http/redirects
  defp put_redirect_method(%{method: :post} = request, status) when status in 301..303 do
    %{request | method: :get}
  end

  defp put_redirect_method(request, _status) do
    request
  end

  defp remove_credentials_if_untrusted(request, true, _), do: request

  defp remove_credentials_if_untrusted(request, _, location_url) do
    if {location_url.host, location_url.scheme, location_url.port} ==
         {request.url.host, request.url.scheme, request.url.port} do
      request
    else
      request
      |> Req.Request.delete_header("authorization")
      |> Req.Request.delete_option(:auth)
    end
  end

  @doc false
  @deprecated "Use Req.Steps.redirect/1 instead"
  def follow_redirects(request_response) do
    follow_redirects(request_response)
  end

  @doc """
  Handles HTTP 4xx/5xx error responses.

  ## Request Options

    * `:http_errors` - how to handle HTTP 4xx/5xx error responses. Can be one of the following:

      * `:return` (default) - return the response

      * `:raise` - raise an error

  ## Examples

      iex> Req.get!("https://httpbin.org/status/404").status
      404

      iex> Req.get!("https://httpbin.org/status/404", http_errors: :raise)
      ** (RuntimeError) The requested URL returned error: 404
      Response body: ""
  """
  @doc step: :response
  def handle_http_errors(request_response)

  def handle_http_errors({request, response}) when response.status >= 400 do
    case Map.get(request.options, :http_errors, :return) do
      :return ->
        {request, response}

      :raise ->
        raise """
        The requested URL returned error: #{response.status}
        Response body: #{inspect(response.body)}\
        """
    end
  end

  def handle_http_errors({request, response}) do
    {request, response}
  end

  ## Error steps

  @doc """
  Retries a request in face of errors.

  This function can be used as either or both response and error step.

  ## Request Options

    * `:retry` - can be one of the following:

        * `:safe_transient` (default) - retry safe (GET/HEAD) requests on HTTP 408/429/500/502/503/504 responses
          or exceptions with `reason` field set to `:timeout`/`:econnrefused`.

        * `:transient` - same as `:safe_transient` except retries all HTTP methods (POST, DELETE, etc.)

        * `fun` - a 2-arity function that accepts a `Req.Request` and either a `Req.Response` or an exception struct
          and returns one of the following:

            * `true` - retry with the default delay controller by default delay option described below.

            * `{:delay, milliseconds}` - retry with the given delay.

            * `false/nil` - don't retry.

        * `false` - don't retry.

    * `:retry_delay` - if not set, which is the default, the retry delay is determined by
      the value of `retry-delay` header on HTTP 429/503 responses. If the header is not set,
      the default delay follows a simple exponential backoff: 1s, 2s, 4s, 8s, ...

      `:retry_delay` can be set to a function that receives the retry count (starting at 0)
      and returns the delay, the number of milliseconds to sleep before making another attempt.

    * `:retry_log_level` - the log level to emit retry logs at. Can also be set to `false` to disable
      logging these messsages. Defaults to `:error`.

    * `:max_retries` - maximum number of retry attempts, defaults to `3` (for a total of `4`
      requests to the server, including the initial one.)

  ## Examples

  With default options:

      iex> Req.get!("https://httpbin.org/status/500,200").status
      # 19:02:08.463 [error] retry: got response with status 500, will retry in 2000ms, 2 attempts left
      # 19:02:10.710 [error] retry: got response with status 500, will retry in 4000ms, 1 attempt left
      200

  Delay with jitter:

      iex> delay = fn n -> trunc(Integer.pow(2, n) * 1000 * (1 - 0.1 * :rand.uniform())) end
      iex> Req.get!("https://httpbin.org/status/500,200", retry_delay: delay).status
      # 08:43:19.101 [error] retry: got response with status 500, will retry in 941ms, 2 attempts left
      # 08:43:22.958 [error] retry: got response with status 500, will retry in 1877s, 1 attempt left
      200

  """
  @doc step: :error
  def retry(request_response_or_error)

  def retry({request, response_or_exception}) do
    retry =
      case Map.get(request.options, :retry, :safe_transient) do
        :safe_transient ->
          safe_transient?(request, response_or_exception)

        :transient ->
          transient?(response_or_exception)

        false ->
          false

        fun when is_function(fun) ->
          apply_retry(fun, request, response_or_exception)

        :safe ->
          IO.warn("setting `retry: :safe` is deprecated in favour of `retry: :safe_transient`")
          safe_transient?(request, response_or_exception)

        :never ->
          IO.warn("setting `retry: :never` is deprecated in favour of `retry: false`")
          false

        other ->
          raise ArgumentError,
                "expected :retry to be :safe_transient, :transient, false, or a 2-arity function, " <>
                  "got: #{inspect(other)}"
      end

    case retry do
      {:delay, delay} ->
        if !Req.Request.get_option(request, :retry_delay) do
          retry(request, response_or_exception, delay)
        else
          raise ArgumentError,
                "expected :retry_delay not to be set when the :retry function is returning `{:delay, milliseconds}`"
        end

      true ->
        retry(request, response_or_exception)

      retry when retry in [false, nil] ->
        {request, response_or_exception}
    end
  end

  defp apply_retry(fun, request, response_or_exception)

  defp apply_retry(fun, _request, response_or_exception) when is_function(fun, 1) do
    IO.warn("`retry: fun/1` has been deprecated in favor of `retry: fun/2`")
    fun.(response_or_exception)
  end

  defp apply_retry(fun, request, response_or_exception) when is_function(fun, 2) do
    fun.(request, response_or_exception)
  end

  defp safe_transient?(request, response_or_exception) do
    request.method in [:get, :head] and transient?(response_or_exception)
  end

  defp transient?(%Req.Response{status: status}) when status in [408, 429, 500, 502, 503, 504] do
    true
  end

  defp transient?(%Req.Response{}) do
    false
  end

  defp transient?(%{__exception__: true, reason: reason})
       when reason in [:timeout, :econnrefused] do
    true
  end

  defp transient?(%{__exception__: true}) do
    false
  end

  defp retry(request, response_or_exception, delay_or_nil \\ nil)

  defp retry(request, response_or_exception, nil) do
    do_retry(request, response_or_exception, &get_retry_delay/3)
  end

  defp retry(request, response_or_exception, delay) when is_integer(delay) do
    do_retry(request, response_or_exception, fn request, _, _ -> {request, delay} end)
  end

  defp do_retry(request, response_or_exception, delay_getter) do
    retry_count = Req.Request.get_private(request, :req_retry_count, 0)
    {request, delay} = delay_getter.(request, response_or_exception, retry_count)
    max_retries = Req.Request.get_option(request, :max_retries, 3)
    log_level = Req.Request.get_option(request, :retry_log_level, :error)

    if retry_count < max_retries do
      log_retry(response_or_exception, retry_count, max_retries, delay, log_level)
      Process.sleep(delay)
      request = Req.Request.put_private(request, :req_retry_count, retry_count + 1)
      {request, response_or_exception} = Req.Request.run_request(request)
      {Req.Request.halt(request), response_or_exception}
    else
      {request, response_or_exception}
    end
  end

  defp get_retry_delay(request, %Req.Response{status: status} = response, retry_count)
       when status in [429, 503] do
    if delay = Req.Response.get_retry_after(response) do
      {request, delay}
    else
      calculate_retry_delay(request, retry_count)
    end
  end

  defp get_retry_delay(request, _response, retry_count) do
    calculate_retry_delay(request, retry_count)
  end

  defp calculate_retry_delay(request, retry_count) do
    case Req.Request.get_option(request, :retry_delay, &exp_backoff/1) do
      delay when is_integer(delay) ->
        {request, delay}

      fun when is_function(fun, 1) ->
        {request, fun.(retry_count)}
    end
  end

  defp exp_backoff(n) do
    Integer.pow(2, n) * 1000
  end

  defp log_retry(_, _, _, _, false), do: :ok

  defp log_retry(response_or_exception, retry_count, max_retries, delay, level) do
    retries_left =
      case max_retries - retry_count do
        1 -> "1 attempt"
        n -> "#{n} attempts"
      end

    message = ["will retry in #{delay}ms, ", retries_left, " left"]

    case response_or_exception do
      %{__exception__: true} = exception ->
        Logger.log(level, [
          "retry: got exception, ",
          message
        ])

        Logger.log(level, [
          "** (#{inspect(exception.__struct__)}) ",
          Exception.message(exception)
        ])

      response ->
        Logger.log(level, ["retry: got response with status #{response.status}, ", message])
    end
  end

  ## Utilities

  defp cache_path(cache_dir, request) do
    cache_key =
      Enum.join(
        [
          request.url.host,
          Atom.to_string(request.method),
          :crypto.hash(:sha256, :erlang.term_to_binary(request.url))
          |> Base.encode16(case: :lower)
        ],
        "-"
      )

    Path.join(cache_dir, cache_key)
  end

  defp write_cache(path, response) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, :erlang.term_to_binary(response))
  end

  defp load_cache(path) do
    path |> File.read!() |> :erlang.binary_to_term()
  end

  @doc false
  def format_http_datetime(datetime) do
    Calendar.strftime(datetime, "%a, %d %b %Y %H:%M:%S GMT")
  end
end
