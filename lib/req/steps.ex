defmodule Req.Steps do
  @moduledoc """
  The collection of built-in steps.

  Req is composed of:

    * `Req` - the high-level API

    * `Req.Request` - the low-level API and the request struct

    * `Req.Steps` - the collection of built-in steps (you're here!)

    * `Req.Test` - the testing conveniences
  """

  require Logger

  @doc false
  def attach(req) do
    req
    |> Req.Request.register_options([
      # request steps
      :user_agent,
      :compressed,
      :range,
      :base_url,
      :params,
      :path_params,
      :path_params_style,
      :auth,
      :form,
      :form_multipart,
      :json,
      :compress_body,
      :checksum,
      :aws_sigv4,

      # response steps
      :raw,
      :http_errors,
      :decode_body,
      :decode_json,
      :redirect,
      :redirect_trusted,
      :redirect_log_level,
      :max_redirects,
      :retry,
      :retry_delay,
      :retry_log_level,
      :max_retries,
      :cache,
      :cache_dir,
      :plug,
      :finch,
      :finch_request,
      :finch_private,
      :connect_options,
      :inet6,
      :receive_timeout,
      :pool_timeout,
      :unix_socket,
      :pool_max_idle_time,

      # TODO: Remove on Req 1.0
      :output,
      :follow_redirects,
      :location_trusted,
      :redact_auth
    ])
    |> Req.Request.prepend_request_steps(
      put_user_agent: &Req.Steps.put_user_agent/1,
      compressed: &Req.Steps.compressed/1,
      encode_body: &Req.Steps.encode_body/1,
      put_base_url: &Req.Steps.put_base_url/1,
      auth: &Req.Steps.auth/1,
      put_params: &Req.Steps.put_params/1,
      put_path_params: &Req.Steps.put_path_params/1,
      put_range: &Req.Steps.put_range/1,
      cache: &Req.Steps.cache/1,
      put_plug: &Req.Steps.put_plug/1,
      compress_body: &Req.Steps.compress_body/1,
      checksum: &Req.Steps.checksum/1,
      put_aws_sigv4: &Req.Steps.put_aws_sigv4/1
    )
    |> Req.Request.prepend_response_steps(
      retry: &Req.Steps.retry/1,
      handle_http_errors: &Req.Steps.handle_http_errors/1,
      redirect: &Req.Steps.redirect/1,
      http_digest: &Req.Steps.handle_http_digest/1,
      decompress_body: &Req.Steps.decompress_body/1,
      verify_checksum: &Req.Steps.verify_checksum/1,
      decode_body: &Req.Steps.decode_body/1,
      output: &Req.Steps.output/1
    )
    |> Req.Request.prepend_error_steps(retry: &Req.Steps.retry/1)
  end

  ## Request steps

  @doc """
  Sets base URL for all requests.

  ## Request Options

    * `:base_url` - if set, the request URL is merged with this base URL.

      The base url can be a string, a `%URI{}` struct, a 0-arity function,
      or a `{mod, fun, args}` tuple describing a function to call.

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
      base_url =
        case base_url do
          binary when is_binary(binary) ->
            binary

          %URI{} = url ->
            URI.to_string(url)

          fun when is_function(fun, 0) ->
            case fun.() do
              binary when is_binary(binary) ->
                binary

              %URI{} = url ->
                URI.to_string(url)
            end

          {mod, fun, args} when is_atom(mod) and is_atom(fun) and is_list(args) ->
            case apply(mod, fun, args) do
              binary when is_binary(binary) ->
                binary

              %URI{} = url ->
                URI.to_string(url)
            end
        end

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

        * `{:basic, userinfo}` - uses Basic HTTP authentication;

        * `{:digest, userinfo}` - uses Digest HTTP authentication;

        * `{:bearer, token}` - uses Bearer HTTP authentication;

        * `:netrc` - load credentials from `.netrc` at path specified in `NETRC` environment variable.
          If `NETRC` is not set, load `.netrc` in user's home directory;

        * `{:netrc, path}` - load credentials from `path`

        * `fn -> {:bearer, "eyJ0eXAi..." } end` - a 0-arity function that returns one of the aforementioned types.

        * `{mod, fun, args}` - an MFArgs tuple that returns one of the aforementioned types.

  ## Examples

      iex> Req.get!("https://httpbin.org/basic-auth/foo/bar", auth: {:basic, "foo:foo"}).status
      401
      iex> Req.get!("https://httpbin.org/basic-auth/foo/bar", auth: {:basic, "foo:bar"}).status
      200
      iex> Req.get!("https://httpbin.org/basic-auth/foo/bar", auth: fn -> {:basic, "foo:bar"} end).status
      200
      iex> Req.get!("https://httpbin.org/basic-auth/foo/bar", auth: {Authentication, :fetch_token, []}).status
      200

      iex> Req.get!("https://httpbin.org/digest-auth/auth/user/pass", auth: {:digest, "user:pass"}).status
      200

      iex> Req.get!("https://httpbin.org/bearer", auth: {:bearer, ""}).status
      401
      iex> Req.get!("https://httpbin.org/bearer", auth: {:bearer, "foo"}).status
      200
      iex> Req.get!("https://httpbin.org/bearer", auth: fn -> {:bearer, "foo"} end).status
      200

      iex> System.put_env("NETRC", "./test/my_netrc")
      iex> Req.get!("https://httpbin.org/basic-auth/foo/bar", auth: :netrc).status
      200

      iex> Req.get!("https://httpbin.org/basic-auth/foo/bar", auth: {:netrc, "./test/my_netrc"}).status
      200
      iex> Req.get!("https://httpbin.org/basic-auth/foo/bar", auth: fn -> {:netrc, "./test/my_netrc"} end).status
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
    Req.Request.put_header(request, "authorization", authorization)
  end

  defp auth(request, {:basic, userinfo}) when is_binary(userinfo) do
    Req.Request.put_header(request, "authorization", "Basic " <> Base.encode64(userinfo))
  end

  defp auth(request, {:bearer, token}) when is_binary(token) do
    Req.Request.put_header(request, "authorization", "Bearer " <> token)
  end

  defp auth(request, {:digest, userinfo}) when is_binary(userinfo) do
    request
  end

  defp auth(request, fun) when is_function(fun, 0) do
    value = fun.()

    if is_function(value, 0) do
      raise ArgumentError, "setting `auth: fn -> ... end` should not return another function"
    end

    auth(request, value)
  end

  defp auth(request, {mod, fun, args}) when is_atom(mod) and is_atom(fun) and is_list(args) do
    value = apply(mod, fun, args)

    auth(request, value)
  end

  defp auth(request, :netrc) do
    path = System.get_env("NETRC") || Path.join(System.user_home!(), ".netrc")
    authenticate_with_netrc(request, path)
  end

  defp auth(request, {:netrc, path}) do
    authenticate_with_netrc(request, path)
  end

  defp auth(request, {username, password}) when is_binary(username) and is_binary(password) do
    IO.warn(
      "setting `auth: {username, password}` is deprecated in favour of `auth: {:basic, userinfo}`"
    )

    Req.Request.put_header(
      request,
      "authorization",
      "Basic " <> Base.encode64("#{username}:#{password}")
    )
  end

  defp authenticate_with_netrc(request, path_or_device) do
    case Map.fetch(Req.Utils.load_netrc(path_or_device), request.url.host) do
      {:ok, {username, password}} ->
        auth(request, {:basic, "#{username}:#{password}"})

      :error ->
        request
    end
  end

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

      When streaming response body (`into: fun | collectable`), `compressed` defaults to `false`.

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
  def compressed(%Req.Request{into: nil} = request) do
    case Req.Request.get_option(request, :compressed, true) do
      true ->
        Req.Request.put_new_header(request, "accept-encoding", supported_accept_encoding())

      false ->
        request
    end
  end

  def compressed(request) do
    request
  end

  defmacrop brotli_loaded? do
    Code.ensure_loaded?(:brotli)
  end

  defmacrop ezstd_loaded? do
    Code.ensure_loaded?(:ezstd)
  end

  defp supported_accept_encoding do
    value = "gzip"
    value = if brotli_loaded?(), do: "br, " <> value, else: value
    if ezstd_loaded?(), do: "zstd, " <> value, else: value
  end

  @doc """
  Encodes the request body.

  ## Request Options

    * `:form` - if set, encodes the request body as `application/x-www-form-urlencoded`
      (using `URI.encode_query/1`).

    * `:form_multipart` - if set, encodes the request body as `multipart/form-data`.

      It accepts `name` / `value` pairs. `value` can be one of:

        * integer (automatically encoded as string)

        * iodata

        * `File.Stream`

        * `Enumerable`

        * `{value, options}` tuple.

           `value` can be any of the values mentioned above.

           Supported options are: `:filename`, `:content_type`, and `:size`.

           When `value` is an `Enumerable`, option `:size` can be set with
           the binary size of the `value`. The size will be used to calculate
           and send the `content-length` header which might be required for
           some servers. There is no need to pass `:size` for `integer`,
           `iodata`, and `File.Stream` values as it's automatically calculated.

    * `:json` - if set, encodes the request body as JSON (using `Jason.encode_to_iodata!/1`), sets
      the `accept` header to `application/json`, and the `content-type` header to `application/json`.

  ## Examples

  Encoding form (`application/x-www-form-urlencoded`):

      iex> Req.post!("https://httpbin.org/anything", form: [a: 1]).body["form"]
      %{"a" => "1"}

  Encoding form (`multipart/form-data`):

      iex> fields = [a: 1, b: {"2", filename: "b.txt"}]
      iex> resp = Req.post!("https://httpbin.org/anything", form_multipart: fields)
      iex> resp.body["form"]
      %{"a" => "1"}
      iex> resp.body["files"]
      %{"b" => "2"}

  Encoding streaming form (`multipart/form-data`):

      iex> stream = Stream.cycle(["abc"]) |> Stream.take(3)
      iex> fields = [file: {stream, filename: "b.txt"}]
      iex> resp = Req.post!("https://httpbin.org/anything", form_multipart: fields)
      iex> resp.body["files"]
      %{"file" => "abcabcabc"}

      # with explicit :size
      iex> stream = Stream.cycle(["abc"]) |> Stream.take(3)
      iex> fields = [file: {stream, filename: "b.txt", size: 9}]
      iex> resp = Req.post!("https://httpbin.org/anything", form_multipart: fields)
      iex> resp.body["files"]
      %{"file" => "abcabcabc"}

  Encoding JSON:

      iex> Req.post!("https://httpbin.org/post", json: %{a: 2}).body["json"]
      %{"a" => 2}
  """
  @doc step: :request
  def encode_body(request) do
    cond do
      data = request.options[:form] ->
        %{request | body: URI.encode_query(data)}
        |> Req.Request.put_new_header("content-type", "application/x-www-form-urlencoded")

      data = request.options[:form_multipart] ->
        multipart = Req.Utils.encode_form_multipart(data)

        %{request | body: multipart.body}
        |> Req.Request.put_new_header("content-type", multipart.content_type)
        |> then(&maybe_put_content_length(&1, multipart.size))

      data = request.options[:json] ->
        %{request | body: Jason.encode_to_iodata!(data)}
        |> Req.Request.put_new_header("content-type", "application/json")
        |> Req.Request.put_new_header("accept", "application/json")

      true ->
        request
    end
  end

  defp maybe_put_content_length(req, nil), do: req

  defp maybe_put_content_length(req, size) do
    Req.Request.put_new_header(req, "content-length", Integer.to_string(size))
  end

  @doc """
  Uses a templated request path.

  By default, params in the URL path are expressed as strings prefixed with `:`. For example,
  `:code` in `https://httpbin.org/status/:code`. If you want to use the `{code}` syntax,
  set `path_params_style: :curly`. Param names must start with a letter and can contain letters,
  digits, and underscores; this is true both for `:colon_params` as well as `{curly_params}`.

  Path params are replaced in the request URL path. The path params are specified as a keyword
  list of parameter names and values, as in the examples below. The values of the parameters are
  converted to strings using the `String.Chars` protocol (`to_string/1`).

  ## Request Options

    * `:path_params` - if set, params to add to the templated path. Defaults to `nil`.

    * `:path_params_style` (*available since v0.5.1*) - how path params are expressed. Can be one of:

         * `:colon` - (default) for Plug-style parameters, such as `:code` in
           `https://httpbin.org/status/:code`.

         * `:curly` - for [OpenAPI](https://swagger.io/specification/)-style parameters, such as
           `{code}` in `https://httpbin.org/status/{code}`.

  ## Examples

      iex> Req.get!("https://httpbin.org/status/:code", path_params: [code: 201]).status
      201

      iex> Req.get!("https://httpbin.org/status/{code}", path_params: [code: 201], path_params_style: :curly).status
      201

  """
  @doc step: :request
  def put_path_params(request) do
    put_path_params(request, Req.Request.get_option(request, :path_params, nil))
  end

  defp put_path_params(request, nil) do
    request
  end

  defp put_path_params(request, params) do
    request
    |> Req.Request.put_private(:path_params_template, request.url.path)
    |> apply_path_params(params)
  end

  defp apply_path_params(request, params) do
    regex =
      case Req.Request.get_option(request, :path_params_style, :colon) do
        :colon -> ~r/:([a-zA-Z]{1}[\w_]*)/
        :curly -> ~r/\{([a-zA-Z]{1}[\w_]*)\}/
      end

    update_in(request.url.path, fn
      nil ->
        nil

      path ->
        Regex.replace(regex, path, fn match, key ->
          case params[String.to_existing_atom(key)] do
            nil -> match
            value -> value |> to_string() |> URI.encode(&URI.char_unreserved?/1)
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

  def put_range(%{options: %{range: first..last//1}} = request) do
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
          |> Req.Utils.format_http_date()

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
    if request.body && request.options[:compress_body] do
      body =
        case request.body do
          iodata when is_binary(iodata) or is_list(iodata) ->
            :zlib.gzip(iodata)

          enumerable ->
            Req.Utils.stream_gzip(enumerable)
        end

      request
      |> Map.replace!(:body, body)
      |> Req.Request.put_header("content-encoding", "gzip")
    else
      request
    end
  end

  @default_finch_options Req.Finch.pool_options(%{})

  @doc """
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

      Req.get!("https://httpbin.org/json", finch: MyFinch)

  More commonly you'd add the the custom Finch pool as part of your supervision tree in your
  `application.ex`:

      children = [
        {Finch,
         name: MyFinch,
         pools: %{
           default: [size: 70]
         }}
      ]

  That way you can also configure a bigger pool size for the HTTP pool. You just mustn't forget to
  pass along `finch: MyFinch` as discussed above. You could use `Req.default_options/1` to make it
  a global default but it's generally discouraged.

  For documentation about the possible pool options and their meaning, please check out the
  [Finch docs on pool configuration options](https://hexdocs.pm/finch/Finch.html#start_link/1-pool-configuration-options).

  ## Request Options

    * `:finch` - the name of the Finch pool. Defaults to a pool automatically started by Req.

    * `:connect_options` - dynamically starts (or re-uses already started) Finch pool with
      the given connection options:

        * `:timeout` - socket connect timeout in milliseconds, defaults to `30_000`.

        * `:protocols` - the HTTP protocols to use, defaults to
          `#{inspect(Keyword.fetch!(@default_finch_options, :protocols))}`.

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

    * `:pool_timeout` - pool checkout timeout in milliseconds, defaults to `5000`.

    * `:receive_timeout` - socket receive timeout in milliseconds, defaults to `15_000`.

    * `:unix_socket` - if set, connect through the given UNIX domain socket.

    * `:pool_max_idle_time` - the maximum number of milliseconds that a pool can be
      idle before being terminated, used only by HTTP1 pools. Default to `:infinity`.

    * `:finch_private` - a map or keyword list of private metadata to add to the Finch request.
      May be useful for adding custom data when handling telemetry with `Finch.Telemetry`.

    * `:finch_request` - a function that executes the Finch request, defaults to using
      `Finch.request/3`.

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
  @doc step: :request
  def run_finch(request) do
    Req.Finch.run(request)
  end

  @doc """
  Sets adapter to `run_plug/1`.

  See `run_plug/1` for more information.

  ## Request Options

    * `:plug` - if set, the plug to run the request through.

  """
  @doc step: :request
  def put_plug(request) do
    if request.options[:plug] do
      %{request | adapter: &run_plug/1}
    else
      request
    end
  end

  @doc """
  Runs the request against a plug instead of over the network.

  This step is a Req _adapter_. It is set as the adapter by the `put_plug/1` step
  if the `:plug` option is set.

  It requires [`:plug`](https://hexdocs.pm/plug) dependency:

      {:plug, "~> 1.0"}

  ## Request Options

    * `:plug` - the plug to run the request through. It can be one of:

        * A _function_ plug: a `fun(conn)` or `fun(conn, options)` function that takes a
          `Plug.Conn` and returns a `Plug.Conn`.

        * A _module_ plug: a `module` name or a `{module, options}` tuple.

      Req automatically calls `Plug.Conn.fetch_query_params/2` before your plug, so you can
      get query params using `conn.query_params`.

      Req also automatically parses request body using `Plug.Parsers` for JSON, urlencoded and
      multipart requests and you can access it with `conn.body_params`. The raw request body of
      the request is available by calling `Req.Test.raw_body/1` with the `conn` in your tests.

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

  which is particularly useful to create HTTP service stubs, similar to tools like
  [Bypass](https://github.com/PSPDFKit-labs/bypass).

  Response streaming is also supported however at the moment the entire response
  body is emitted as one chunk:

      test "echo" do
        plug = fn conn ->
          conn = Plug.Conn.send_chunked(conn, 200)
          {:ok, conn} = Plug.Conn.chunk(conn, "echo")
          {:ok, conn} = Plug.Conn.chunk(conn, "echo")
          conn
        end

        assert Req.get!(plug: plug, into: []).body == ["echoecho"]
      end

  When testing JSON APIs, it's common to use the `Req.Test.json/2` helper:

      test "JSON" do
        plug = fn conn ->
          Req.Test.json(conn, %{message: "Hello, World!"})
        end

        resp = Req.get!(plug: plug)
        assert resp.status == 200
        assert resp.headers["content-type"] == ["application/json; charset=utf-8"]
        assert resp.body == %{"message" => "Hello, World!"}
      end

  You can simulate network errors by calling `Req.Test.transport_error/2`
  in your plugs:

      test "network issues" do
        plug = fn conn ->
          Req.Test.transport_error(conn, :timeout)
        end

        assert Req.get(plug: plug, retry: false) ==
                 {:error, %Req.TransportError{reason: :timeout}}
      end
  """
  @doc step: :request
  def run_plug(request)

  if Code.ensure_loaded?(Plug.Test) do
    def run_plug(request) do
      plug = request.options.plug

      req_body =
        case request.body do
          iodata when is_binary(iodata) or is_list(iodata) ->
            IO.iodata_to_binary(iodata)

          nil ->
            ""

          enumerable ->
            enumerable |> Enum.to_list() |> IO.iodata_to_binary()
        end

      {req_body, request} =
        case Req.Request.get_header(request, "content-encoding") do
          [] ->
            {req_body, request}

          encoding_headers ->
            case decompress_with_encoding(encoding_headers, req_body) do
              %Req.DecompressError{} = error ->
                raise error

              {decompressed_body, _unknown_codecs} ->
                {decompressed_body, Req.Request.delete_header(request, "content-encoding")}
            end
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

      parser_opts =
        Plug.Parsers.init(
          parsers: [:urlencoded, :multipart, :json],
          pass: ["*/*"],
          json_decoder: Jason
        )

      conn =
        Req.Test.Adapter.conn(%Plug.Conn{}, request.method, request.url, req_body)
        |> Map.replace!(:req_headers, req_headers)
        |> Plug.Conn.fetch_query_params()
        |> Plug.Parsers.call(parser_opts)

      # Handle cases where the body isn't read with Plug.Parsers
      {mod, state} = conn.adapter
      state = %{state | body_read: true}
      conn = %{conn | adapter: {mod, state}}
      conn = call_plug(conn, plug)

      unless match?(%Plug.Conn{}, conn) do
        raise ArgumentError, "expected to return %Plug.Conn{}, got: #{inspect(conn)}"
      end

      if exception = conn.private[:req_test_exception] do
        {request, exception}
      else
        handle_plug_result(conn, request)
      end
    end

    defp handle_plug_result(conn, request) do
      # consume messages sent by Plug.Test adapter
      {_, %{ref: ref}} = conn.adapter

      if conn.state == :unset do
        raise """
        expected connection to have a response but no response was set/sent.

        Please verify that you are using Plug.Conn.send_resp/3 in your plug:

            Req.Test.stub(MyStub, fn conn, ->
              Plug.Conn.send_resp(conn, 200, "Hello, World!")
            end)
        """
      end

      receive do
        {^ref, {_status, _headers, _body}} -> :ok
      after
        0 -> :ok
      end

      receive do
        {:plug_conn, :sent} -> :ok
      after
        0 -> :ok
      end

      case request.into do
        nil ->
          response =
            Req.Response.new(
              status: conn.status,
              headers: conn.resp_headers,
              body: conn.resp_body
            )

          {request, response}

        fun when is_function(fun, 2) ->
          response =
            Req.Response.new(
              status: conn.status,
              headers: conn.resp_headers
            )

          case fun.({:data, conn.resp_body}, {request, response}) do
            {:cont, acc} ->
              acc

            {:halt, acc} ->
              acc

            other ->
              raise ArgumentError, "expected {:cont, acc}, got: #{inspect(other)}"
          end

        :self ->
          async = %Req.Response.Async{
            pid: self(),
            ref: make_ref(),
            stream_fun: &plug_parse_message/2,
            cancel_fun: &plug_cancel/1
          }

          resp = Req.Response.new(status: conn.status, headers: conn.resp_headers, body: async)
          send(self(), {async.ref, {:data, conn.resp_body}})
          send(self(), {async.ref, :done})
          {request, resp}

        collectable ->
          response =
            Req.Response.new(
              status: conn.status,
              headers: conn.resp_headers
            )

          if conn.status == 200 do
            {acc, collector} = Collectable.into(collectable)
            acc = collector.(acc, {:cont, conn.resp_body})
            acc = collector.(acc, :done)
            {request, %{response | body: acc}}
          else
            {request, %{response | body: conn.resp_body}}
          end
      end
    end

    defp plug_parse_message(ref, {ref, {:data, data}}) do
      {:ok, [data: data]}
    end

    defp plug_parse_message(ref, {ref, :done}) do
      {:ok, [:done]}
    end

    defp plug_parse_message(_, _) do
      :unknown
    end

    defp plug_cancel(ref) do
      plug_clean_responses(ref)
      :ok
    end

    defp plug_clean_responses(ref) do
      receive do
        {^ref, _} -> plug_clean_responses(ref)
      after
        0 -> :ok
      end
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

    defp call_plug(conn, plug) when is_function(plug, 2) do
      plug.(conn, [])
    end
  else
    def run_plug(_request) do
      Logger.error("""
      Could not find plug dependency.

      Please add :plug to your dependencies:

          {:plug, "~> 1.0"}
      """)

      raise "missing plug dependency"
    end
  end

  @doc """
  Sets expected response body checksum.

  ## Request Options

    * `:checksum` - if set, this is the expected response body checksum.

      Can be one of:

        * `"md5:(...)"`
        * `"sha1:(...)"`
        * `"sha256:(...)"`

  ## Examples

      iex> resp = Req.get!("https://httpbin.org/json", checksum: "sha1:9274ffd9cf273d4a008750f44540c4c5d4c8227c")
      iex> resp.status
      200

      iex> Req.get!("https://httpbin.org/json", checksum: "sha1:bad")
      ** (Req.ChecksumMismatchError) checksum mismatch
      expected: sha1:bad
      actual:   sha1:9274ffd9cf273d4a008750f44540c4c5d4c8227c
  """
  @doc step: :request
  def checksum(request) do
    case Req.Request.get_option(request, :checksum) do
      nil ->
        request

      checksum when is_binary(checksum) ->
        type = checksum_type(checksum)

        case request.into do
          nil ->
            Req.Request.put_private(request, :req_checksum, %{
              type: type,
              expected: checksum,
              hash: :body
            })

          fun when is_function(fun, 2) ->
            hash = hash_init(type)

            into =
              fn {:data, chunk}, {req, resp} ->
                req = update_in(req.private.req_checksum.hash, &:crypto.hash_update(&1, chunk))
                fun.({:data, chunk}, {req, resp})
              end

            request
            |> Req.Request.put_private(:req_checksum, %{
              type: type,
              expected: checksum,
              hash: hash
            })
            |> Map.replace!(:into, into)

          :self ->
            raise ArgumentError, ":checksum cannot be used with `into: :self`"

          collectable ->
            into = Req.Utils.collect_with_hash(collectable, type)

            request
            |> Req.Request.put_private(:req_checksum, %{
              type: type,
              expected: checksum,
              hash: :collectable
            })
            |> Map.replace!(:into, into)
        end
    end
  end

  defp checksum_type("md5:" <> _), do: :md5
  defp checksum_type("sha1:" <> _), do: :sha1
  defp checksum_type("sha256:" <> _), do: :sha256

  defp hash_init(:sha1), do: hash_init(:sha)
  defp hash_init(type), do: :crypto.hash_init(type)

  @doc """
  Signs request with AWS Signature Version 4.

  ## Request Options

    * `:aws_sigv4` - if set, the AWS options to sign request:

        * `:access_key_id` - the AWS access key id.

        * `:secret_access_key` - the AWS secret access key.

        * `:token` - if set, the AWS security token, for example returned from AWS STS.

        * `:service` - the AWS service. We try to automatically detect the service (e.g.
          `s3.amazonaws.com` host sets service to `:s3`)

        * `:region` - the AWS region. Defaults to `"us-east-1"`.

        * `:datetime` - the request datetime, defaults to `DateTime.utc_now(:second)`.

      Additionally, it can be an `{mod, fun, args}` tuple that returns the above
      options.

  ## Examples

      iex> req =
      ...>   Req.new(
      ...>     base_url: "https://s3.amazonaws.com",
      ...>     aws_sigv4: [
      ...>       access_key_id: System.get_env("AWS_ACCESS_KEY_ID"),
      ...>       secret_access_key: System.get_env("AWS_SECRET_ACCESS_KEY")
      ...>     ]
      ...>   )
      iex>
      iex> %{status: 200} = Req.put!(req, url: "/bucket1/key1", body: "Hello, World!")
      iex> resp = Req.get!(req, url: "/bucket1/key1").body
      "Hello, World!"

  Request body streaming also works though `content-length` header must be explicitly set:

      iex> path = "a.txt"
      iex> File.write!(path, String.duplicate("a", 100_000))
      iex> size = File.stat!(path).size
      iex> chunk_size = 10 * 1024
      iex> stream = File.stream!(path, chunk_size)
      iex> %{status: 200} = Req.put!(req, url: "/key1", headers: [content_length: size], body: stream)
      iex> byte_size(Req.get!(req, "/bucket1/key1").body)
      100_000
  """
  @doc step: :request
  def put_aws_sigv4(request) do
    if aws_options = request.options[:aws_sigv4] do
      aws_options =
        aws_options
        |> parse_aws_sigv4_options()
        |> Keyword.put_new(:region, "us-east-1")
        |> Keyword.put_new(:datetime, DateTime.utc_now())
        # aws_credentials returns this key so let's ignore it
        |> Keyword.drop([:credential_provider])

      Req.Request.validate_options(aws_options, [
        :access_key_id,
        :secret_access_key,
        :token,
        :service,
        :region,
        :datetime,

        # for req_s3
        :expires
      ])

      unless aws_options[:access_key_id] do
        raise ArgumentError, "missing :access_key_id in :aws_sigv4 option"
      end

      unless aws_options[:secret_access_key] do
        raise ArgumentError, "missing :secret_access_key in :aws_sigv4 option"
      end

      aws_options = ensure_aws_service(aws_options, request.url)

      {body, options} =
        case request.body do
          nil ->
            {"", []}

          iodata when is_binary(iodata) or is_list(iodata) ->
            {iodata, []}

          _enumerable ->
            if Req.Request.get_header(request, "content-length") == [] do
              raise "content-length header must be explicitly set when streaming request body"
            end

            {"", [body_digest: "UNSIGNED-PAYLOAD"]}
        end

      request = Req.Request.put_new_header(request, "host", request.url.host)

      headers = for {name, values} <- request.headers, value <- values, do: {name, value}

      headers =
        Req.Utils.aws_sigv4_headers(
          aws_options ++
            [
              method: request.method,
              url: to_string(request.url),
              headers: headers,
              body: body
            ] ++ options
        )

      Req.merge(request, headers: headers)
    else
      request
    end
  end

  defp parse_aws_sigv4_options(aws_options) do
    case aws_options do
      list when is_list(list) ->
        list

      map when is_map(map) ->
        Enum.to_list(map)

      {mod, fun, args} when is_atom(mod) and is_atom(fun) and is_list(args) ->
        mod
        |> apply(fun, args)
        |> parse_aws_sigv4_options()

      other ->
        raise ArgumentError,
              ":aws_sigv4 must be a keywords list or a map, got: #{inspect(other)}"
    end
  end

  defp ensure_aws_service(options, url) do
    if options[:service] do
      options
    else
      if service = detect_aws_service(url) do
        Keyword.put(options, :service, service)
      else
        raise ArgumentError, "missing :service in :aws_sigv4 option"
      end
    end
  end

  defp detect_aws_service(%URI{} = url) do
    parts = (url.host || "") |> String.split(".") |> Enum.reverse()

    with ["com", "amazonaws" | rest] <- parts do
      case rest do
        # s3
        ["s3" | _] -> :s3
        [_region, "s3" | _] -> :s3
        # sqs
        ["sqs" | _] -> :sqs
        [_region, "sqs" | _] -> :sqs
        # ses
        ["email" | _] -> :ses
        [_region, "email" | _] -> :ses
        # iam
        ["iam"] -> :iam
        _ -> nil
      end
    else
      _ -> nil
    end
  end

  ## Response steps

  @doc """
  Verifies the response body checksum.

  See `checksum/1` for more information.
  """
  @doc step: :response
  def verify_checksum({request, response}) do
    if config = request.private[:req_checksum] do
      {response, hash} =
        case config.hash do
          # The most efficient way to do this would be to calculate checksum one chunk
          # at a time but it's not easy to implemenet.
          :body ->
            hash = hash_init(config.type)
            hash = :crypto.hash_update(hash, response.body)
            {response, :crypto.hash_final(hash)}

          :collectable ->
            {body, hash} = response.body
            {put_in(response.body, body), hash}

          hash ->
            {response, :crypto.hash_final(hash)}
        end

      actual = "#{config.type}:" <> Base.encode16(hash, case: :lower, padding: false)

      if config.expected == actual do
        request = Req.Request.delete_option(request, :req_checksum)
        {request, response}
      else
        exception = Req.ChecksumMismatchError.exception(expected: config.expected, actual: actual)
        {request, exception}
      end
    else
      {request, response}
    end
  end

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

    * `content-encoding` is removed
    * `content-length` is removed

  ## Options

    * `:raw` - if set to `true`, disables response body decompression. Defaults to `false`.

      Note: setting `raw: true` also disables response body decoding in the `decode_body/1` step.

  ## Examples

      iex> response = Req.get!("https://httpbin.org/gzip")
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
      encoding_headers = Req.Response.get_header(response, "content-encoding")

      case decompress_with_encoding(encoding_headers, response.body) do
        %Req.DecompressError{} = exception ->
          {request, exception}

        {decompressed_body, unknown_codecs} ->
          response = put_in(response.body, decompressed_body)

          response =
            if unknown_codecs == [] do
              response
              |> Req.Response.delete_header("content-encoding")
              |> Req.Response.delete_header("content-length")
            else
              Req.Response.put_header(
                response,
                "content-encoding",
                Enum.join(unknown_codecs, ", ")
              )
            end

          {request, response}
      end
    end
  end

  defp decompress_with_encoding([], body), do: {body, []}

  defp decompress_with_encoding(encoding_headers, body) do
    codecs = compression_algorithms(encoding_headers)
    decompress_body(codecs, body, [])
  end

  defp decompress_body([gzip | rest], body, acc) when gzip in ["gzip", "x-gzip"] do
    try do
      decompress_body(rest, :zlib.gunzip(body), acc)
    rescue
      e in ErlangError ->
        if e.original == :data_error do
          %Req.DecompressError{format: :gzip, data: body}
        else
          reraise e, __STACKTRACE__
        end
    end
  end

  defp decompress_body(["br" | rest], body, acc) do
    if brotli_loaded?() do
      case :brotli.decode(body) do
        {:ok, decompressed} ->
          decompress_body(rest, decompressed, acc)

        :error ->
          %Req.DecompressError{format: :br, data: body}
      end
    else
      Logger.debug(":brotli library not loaded, skipping brotli decompression")
      decompress_body(rest, body, ["br" | acc])
    end
  end

  defp decompress_body(["zstd" | rest], body, acc) do
    if ezstd_loaded?() do
      case :ezstd.decompress(body) do
        decompressed when is_binary(decompressed) ->
          decompress_body(rest, decompressed, acc)

        {:error, reason} ->
          %Req.DecompressError{format: :zstd, data: body, reason: reason}
      end
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
    Code.ensure_loaded?(NimbleCSV)
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

  | Format       | Decoder                                                           |
  | ------------ | ----------------------------------------------------------------- |
  | `json`       | `Jason.decode/2`                                                  |
  | `tar`, `tgz` | `:erl_tar.extract/2`                                              |
  | `zip`        | `:zip.unzip/2`                                                    |
  | `gzip`       | `:zlib.gunzip/1`                                                  |
  | `zst`        | `:ezstd.decompress/1` (if [ezstd] is installed)                   |
  | `csv`        | `NimbleCSV.RFC4180.parse_string/2` (if [nimble_csv] is installed) |

  The format is determined based on the `content-type` header of the response. For example,
  if the `content-type` is `application/json`, the response body is decoded as JSON. The built-in
  decoders also understand format extensions, such as decoding as JSON for a content-type of
  `application/vnd.api+json`. To do this, Req falls back to `MIME.extensions/1`; check the
  documentation for that function for more information.

  This step is disabled on response body streaming. If response body is not a binary, in other
  words it has been transformed by another step, it is left as is.

  ## Request Options

    * `:decode_body` - if set to `false`, disables automatic response body decoding.
      Defaults to `true`.

    * `:decode_json` - options to pass to `Jason.decode/2`, defaults to `[]`.

    * `:raw` - if set to `true`, disables response body decoding. Defaults to `false`.

      Note: setting `raw: true` also disables response body decompression in the
      `decompress_body/1` step.

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
  [ezstd]: https://hex.pm/packages/ezstd
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

    case Jason.decode(response.body, options) do
      {:ok, decoded} ->
        {request, put_in(response.body, decoded)}

      {:error, e} ->
        {request, e}
    end
  end

  defp decode_body({request, response}, "tar") do
    case :erl_tar.extract({:binary, response.body}, [:memory]) do
      {:ok, files} ->
        {request, put_in(response.body, files)}

      {:error, reason} ->
        {request, %Req.ArchiveError{format: :tar, data: response.body, reason: reason}}
    end
  end

  defp decode_body({request, response}, "tgz") do
    case :erl_tar.extract({:binary, response.body}, [:memory, :compressed]) do
      {:ok, files} ->
        {request, put_in(response.body, files)}

      {:error, reason} ->
        {request, %Req.ArchiveError{format: :tar, data: response.body, reason: reason}}
    end
  end

  defp decode_body({request, response}, "zip") do
    case :zip.extract(response.body, [:memory]) do
      {:ok, files} ->
        {request, put_in(response.body, files)}

      {:error, _} ->
        {request, %Req.ArchiveError{format: :zip, data: response.body}}
    end
  end

  defp decode_body({request, response}, "gz") do
    {request, update_in(response.body, &:zlib.gunzip/1)}
  end

  defp decode_body({request, response}, "zst") do
    if ezstd_loaded?() do
      case :ezstd.decompress(response.body) do
        decompressed when is_binary(decompressed) ->
          {request, put_in(response.body, decompressed)}

        {:error, reason} ->
          err = %RuntimeError{message: "Could not decompress Zstandard data: #{inspect(reason)}"}
          {request, err}
      end
    else
      {request, response}
    end
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
    path = request.url.path || ""

    case Req.Response.get_header(response, "content-type") do
      [content_type | _] ->
        case extensions(content_type, path) do
          [ext | _] -> ext
          [] -> nil
        end

      [] ->
        case extensions("application/octet-stream", path) do
          [ext | _] -> ext
          [] -> nil
        end
    end
  end

  defp extensions("application/octet-stream" <> _, path) do
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
      to `false` to disable logging these messages. Defaults to `:debug`.

    * `:max_redirects` - the maximum number of redirects, defaults to `10`. If the
      limit is reached, the pipeline is halted and a `Req.TooManyRedirectsError`
      exception is returned.

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

    with true <- redirect? && response.status in [301, 302, 303, 307, 308],
         [location | _] <- Req.Response.get_header(response, "location") do
      max_redirects = Req.Request.get_option(request, :max_redirects, 10)
      redirect_count = Req.Request.get_private(request, :req_redirect_count, 0)

      if redirect_count < max_redirects do
        with %Req.Response.Async{} <- response.body do
          Req.cancel_async_response(response)
        end

        request =
          request
          |> build_redirect_request(response, location)
          |> Req.Request.put_private(:req_redirect_count, redirect_count + 1)

        {request, response_or_exception} = Req.Request.run_request(request)
        Req.Request.halt(request, response_or_exception)
      else
        Req.Request.halt(request, %Req.TooManyRedirectsError{max_redirects: max_redirects})
      end
    else
      _ ->
        {request, response}
    end
  end

  defp build_redirect_request(request, response, location) do
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

    location_url =
      request.url
      |> URI.merge(URI.parse(location))
      |> normalize_redirect_uri()

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

  defp normalize_redirect_uri(%URI{scheme: "http", port: nil} = uri), do: %{uri | port: 80}
  defp normalize_redirect_uri(%URI{scheme: "https", port: nil} = uri), do: %{uri | port: 443}
  defp normalize_redirect_uri(%URI{} = uri), do: uri

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

  @doc """
  Handles HTTP Digest authentication.

  This step is invoked when setting `:auth` option with `{:digest, ...}`. When response is HTTP 401 with `www-authenticate` header, this step will calculate `authorization: Digest ...` header and make another request.

  See `auth/1`.

  ## Examples

      iex> resp = Req.get!("https://httpbin.org/digest-auth/auth/user/pass", auth: {:digest, "user:pass"})
      iex> resp.status
      200
  """
  @doc step: :response
  def handle_http_digest({request, %Req.Response{status: 401} = response}) do
    with {:digest, userinfo} <- request.options[:auth],
         [username, password] <- String.split(userinfo, ":", parts: 2),
         ["Digest " <> _ = challenge_header | _] <-
           Req.Response.get_header(response, "www-authenticate"),
         {:ok, auth_header_value} <-
           Req.Utils.http_digest_auth(
             challenge_header,
             username,
             password,
             request.method || :get,
             request.url.path || "/"
           ) do
      request
      |> Req.Request.delete_option(:auth)
      |> Req.Request.put_header("authorization", auth_header_value)
      |> Req.Request.run_request()
    else
      {:error, {:unsupported_digest_algorithm, algorithm}} ->
        Logger.warning("unsupported digest algorithm sent by the server: #{algorithm}")
        {request, response}

      _ ->
        {request, response}
    end
  end

  def handle_http_digest(other) do
    other
  end

  ## Error steps

  @doc """
  Retries a request in face of errors.

  This function can be used as either or both response and error step.

  ## Request Options

    * `:retry` - can be one of the following:

        * `:safe_transient` (default) - retry safe (GET/HEAD) requests on one of:

            * HTTP 408/429/500/502/503/504 responses

            * `Req.TransportError` with `reason: :timeout | :econnrefused | :closed`

            * `Req.HTTPError` with `protocol: :http2, reason: :unprocessed`

        * `:transient` - same as `:safe_transient` except retries all HTTP methods (POST, DELETE, etc.)

        * `fun` - a 2-arity function that accepts a `Req.Request` and either a `Req.Response` or an exception struct
          and returns one of the following:

            * `true` - retry with the default delay controller by default delay option described below.

            * `{:delay, milliseconds}` - retry with the given delay.

            * `false/nil` - don't retry.

        * `false` - don't retry.

    * `:retry_delay` - if not set, which is the default, the retry delay is determined by
      the value of the `Retry-After` header on HTTP 429/503 responses. If the header is not set,
      or the header value is negative, the default delay follows a simple exponential backoff:
      1s, 2s, 4s, 8s, ...

      `:retry_delay` can be set to a function that receives the retry count (starting at 0)
      and returns the delay, the number of milliseconds to sleep before making another attempt.

    * `:retry_log_level` - the log level to emit retry logs at. Can also be set to `false` to disable
      logging these messages. Defaults to `:warning`.

    * `:max_retries` - maximum number of retry attempts, defaults to `3` (for a total of `4`
      requests to the server, including the initial one.)

  ## Examples

  With default options:

      iex> Req.get!("https://httpbin.org/status/500,200").status
      # 19:02:08.463 [warning] retry: got response with status 500, will retry in 2000ms, 2 attempts left
      # 19:02:10.710 [warning] retry: got response with status 500, will retry in 4000ms, 1 attempt left
      200

  Delay with jitter:

      iex> delay = fn n -> trunc(Integer.pow(2, n) * 1000 * (1 - 0.1 * :rand.uniform())) end
      iex> Req.get!("https://httpbin.org/status/500,200", retry_delay: delay).status
      # 08:43:19.101 [warning] retry: got response with status 500, will retry in 941ms, 2 attempts left
      # 08:43:22.958 [warning] retry: got response with status 500, will retry in 1877ms, 1 attempt left
      200

  """
  @doc step: :error
  def retry(request_response_or_error)

  def retry({request, response_or_exception}) do
    retry =
      case Map.get(request.options, :retry, :safe_transient) do
        :safe_transient ->
          request.method in [:get, :head] and transient?(response_or_exception)

        :transient ->
          transient?(response_or_exception)

        false ->
          false

        fun when is_function(fun) ->
          apply_retry(fun, request, response_or_exception)

        :safe ->
          IO.warn("setting `retry: :safe` is deprecated in favour of `retry: :safe_transient`")
          request.method in [:get, :head] and transient?(response_or_exception)

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

  defp transient?(%Req.Response{status: status}) when status in [408, 429, 500, 502, 503, 504] do
    true
  end

  defp transient?(%Req.Response{}) do
    false
  end

  defp transient?(%Req.TransportError{reason: reason})
       when reason in [:timeout, :econnrefused, :closed] do
    true
  end

  defp transient?(%Req.HTTPError{protocol: :http2, reason: :unprocessed}) do
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
    log_level = Req.Request.get_option(request, :retry_log_level, :warning)

    if retry_count < max_retries do
      log_retry(response_or_exception, retry_count, max_retries, delay, log_level)
      Process.sleep(delay)
      request = Req.Request.put_private(request, :req_retry_count, retry_count + 1)
      {request, response_or_exception} = Req.Request.run_request(%{request | halted: false})
      Req.Request.halt(request, response_or_exception)
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
        case fun.(retry_count) do
          delay when is_integer(delay) and delay >= 0 ->
            {request, delay}

          other ->
            raise ArgumentError,
                  "expected :retry_delay function to return non-negative integer, got: #{inspect(other)}"
        end
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
end
