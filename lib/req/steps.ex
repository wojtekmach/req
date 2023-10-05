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
    auth(request, Map.get(request.options, :auth))
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
    user_agent = Map.get(request.options, :user_agent, @user_agent)
    Req.Request.put_new_header(request, "user-agent", user_agent)
  end

  @doc """
  Asks the server to return compressed response.

  Supported formats:

    * `gzip`
    * `deflate`
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
      #=> "zstd, br, gzip, deflate"

  [brotli]: https://hex.pm/packages/brotli
  [ezstd]: https://hex.pm/packages/ezstd
  """
  @doc step: :request
  def compressed(request) do
    case Map.fetch(request.options, :compressed) do
      :error ->
        Req.Request.put_new_header(request, "accept-encoding", supported_accept_encoding())

      {:ok, true} ->
        Req.Request.put_new_header(request, "accept-encoding", supported_accept_encoding())

      {:ok, false} ->
        request
    end
  end

  defmacrop brotli_loaded? do
    Code.ensure_loaded?(:brotli)
  end

  defmacrop ezstd_loaded? do
    Code.ensure_loaded?(:ezstd)
  end

  defp supported_accept_encoding do
    value = "gzip, deflate"
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
    put_path_params(request, Map.get(request.options, :path_params, []))
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
    put_params(request, Map.get(request.options, :params, []))
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

    * `:cache` - if `true`, performs caching. Defaults to `false`.

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
    if request.options[:cache] do
      dir = Map.get(request.options, :cache_dir) || :filename.basedir(:user_cache, ~c"req")
      cache_path = cache_path(dir, request)

      request
      |> put_if_modified_since(cache_path)
      |> Req.Request.prepend_response_steps(handle_cache: &handle_cache(&1, cache_path))
    else
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
      request
      |> Map.update!(:body, &:zlib.gzip/1)
      |> Req.Request.put_header("content-encoding", "gzip")
    else
      request
    end
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

    * `:pool_timeout` - pool checkout timeout in milliseconds, defaults to `5000`.

    * `:receive_timeout` - socket receive timeout in milliseconds, defaults to `15_000`.

    * `:unix_socket` - if set, connect through the given UNIX domain socket

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

  Stream response body:

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

    finch_request =
      Finch.build(request.method, request.url, request.headers, request.body)
      |> Map.replace!(:unix_socket, request.options[:unix_socket])

    finch_options =
      request.options |> Map.take([:receive_timeout, :pool_timeout]) |> Enum.to_list()

    run_finch(request, finch_request, finch_name, finch_options)
  end

  defp run_finch(request, finch_request, finch_name, finch_options) do
    case Map.fetch(request.options, :finch_request) do
      {:ok, fun} when is_function(fun, 4) ->
        fun.(request, finch_request, finch_name, finch_options)

      {:ok, deprecated_fun} when is_function(deprecated_fun, 1) ->
        IO.warn(
          "passing a :finch_request function accepting a single argument is deprecated. " <>
            "See Req.Steps.run_finch/1 for more information."
        )

        {request, run_finch_request(deprecated_fun.(finch_request), finch_name, finch_options)}

      :error ->
        {request, run_finch_request(finch_request, finch_name, finch_options)}
    end
  end

  defp run_finch_request(finch_request, finch_name, finch_options) do
    case Finch.request(finch_request, finch_name, finch_options) do
      {:ok, response} -> Req.Response.new(response)
      {:error, exception} -> exception
    end
  end

  defp finch_name(request) do
    case Map.fetch(request.options, :finch) do
      {:ok, name} ->
        if request.options[:connect_options] do
          raise ArgumentError, "cannot set both :finch and :connect_options"
        end

        name

      :error ->
        cond do
          options = request.options[:connect_options] ->
            Req.Request.validate_options(
              options,
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

            hostname_opts = Keyword.take(options, [:hostname])

            transport_opts = [
              transport_opts:
                Keyword.merge(
                  Keyword.take(options, [:timeout]),
                  Keyword.get(options, :transport_opts, [])
                )
            ]

            proxy_headers_opts = Keyword.take(options, [:proxy_headers])
            proxy_opts = Keyword.take(options, [:proxy])
            client_settings_opts = Keyword.take(options, [:client_settings])

            pool_opts = [
              conn_opts:
                hostname_opts ++
                  transport_opts ++
                  proxy_headers_opts ++
                  proxy_opts ++
                  client_settings_opts,
              protocol: options[:protocol] || :http1
            ]

            name =
              options
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

          true ->
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
    body = IO.iodata_to_binary(request.body || "")

    conn =
      Plug.Test.conn(request.method, request.url, body)
      |> Map.replace!(:req_headers, request.headers)
      |> call_plug(request.options.plug)

    response = %Req.Response{
      status: conn.status,
      headers: conn.resp_headers,
      body: conn.resp_body
    }

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

  Supported formats:

  | Format        | Decoder                                         |
  | ------------- | ----------------------------------------------- |
  | gzip, x-gzip  | `:zlib.gunzip/1`                                |
  | deflate       | `:zlib.unzip/1`                                 |
  | br            | `:brotli.decode/1` (if [brotli] is installed)   |
  | zstd          | `:ezstd.decompress/1` (if [ezstd] is installed) |
  | identity      | Returns data as is                              |

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

  def decompress_body({request, response})
      when request.options.raw == true or
             response.body == "" or
             not is_binary(response.body) do
    {request, response}
  end

  def decompress_body({request, response}) do
    compression_algorithms = get_content_encoding_header(response.headers)
    {request, update_in(response.body, &decompress_body(&1, compression_algorithms))}
  end

  defp decompress_body(body, algorithms) do
    Enum.reduce(algorithms, body, &decompress_with_algorithm(&1, &2))
  end

  defp decompress_with_algorithm(gzip, body) when gzip in ["gzip", "x-gzip"] do
    :zlib.gunzip(body)
  end

  defp decompress_with_algorithm("deflate", body) do
    :zlib.unzip(body)
  end

  defp decompress_with_algorithm("br", body) do
    if brotli_loaded?() do
      {:ok, decompressed} = :brotli.decode(body)
      decompressed
    else
      raise("`:brotli` decompression library not loaded")
    end
  end

  defp decompress_with_algorithm("zstd", body) do
    if ezstd_loaded?() do
      :ezstd.decompress(body)
    else
      raise("`:ezstd` decompression library not loaded")
    end
  end

  defp decompress_with_algorithm("identity", body) do
    body
  end

  defp decompress_with_algorithm(algorithm, _body) do
    raise("unsupported decompression algorithm: #{inspect(algorithm)}")
  end

  defmacrop nimble_csv_loaded? do
    Code.ensure_loaded?(NimbleCSV)
  end

  @doc """
  Writes the response body to a file.

  After the output file is written, the response body is set to `""`.

  ## Request Options

    * `:output` - if set, writes the response body to a file. Can be one of:

        * `path` - writes to the given path

        * `:remote_name` - uses the remote name as the filename in the current working directory

  ## Examples

      iex> Req.get!("https://elixir-lang.org/index.html", output: "/tmp/elixir_home.html")
      iex> File.exists?("/tmp/elixir_home.html")
      true

      iex> Req.get!("https://elixir-lang.org/blog/index.html", output: :remote_name)
      iex> File.exists?("index.html")
      true
  """
  @doc step: :response
  def output(request_response)

  def output({request, response}) do
    output({request, response}, Map.get(request.options, :output))
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

  def decode_body({request, %{body: ""} = response}) do
    {request, response}
  end

  def decode_body({request, response}) when not is_binary(response.body) do
    {request, response}
  end

  def decode_body({request, response}) when request.options.raw == true do
    {request, response}
  end

  def decode_body({request, response}) when request.options.decode_body == false do
    {request, response}
  end

  def decode_body({request, response}) do
    decode_body({request, response}, format(request, response))
  end

  defp decode_body({request, response}, format) when format in ~w(json json-api) do
    options = Map.get(request.options, :decode_json, [])
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
    with {_, content_type} <- List.keyfind(response.headers, "content-type", 0) do
      # remove ` || ` when we require Elixir v1.13
      path = request.url.path || ""

      case extensions(content_type, path) do
        [ext | _] -> ext
        [] -> nil
      end
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

    * `:follow_redirects` - if set to `false`, disables automatic response redirects.
      Defaults to `true`.

    * `:location_trusted` - by default, authorization credentials are only sent
      on redirects with the same host, scheme and port. If `:location_trusted` is set
      to `true`, credentials will be sent to any host.

    * `:max_redirects` - the maximum number of redirects, defaults to `10`.
      If the limit is reached, an error is raised.

    * `:redirect_log_level` - the log level to emit redirect logs at. Can also be set
      to `false` to disable logging these messsages. Defaults to `:debug`.

  ## Examples

      iex> Req.get!("http://api.github.com").status
      # 23:24:11.670 [debug]  follow_redirects: redirecting to https://api.github.com/
      200

      iex> Req.get!("https://httpbin.org/redirect/4", max_redirects: 3)
      # 23:07:59.570 [debug] follow_redirects: redirecting to /relative-redirect/3
      # 23:08:00.068 [debug] follow_redirects: redirecting to /relative-redirect/2
      # 23:08:00.206 [debug] follow_redirects: redirecting to /relative-redirect/1
      ** (RuntimeError) too many redirects (3)

      iex> Req.get!("http://api.github.com", redirect_log_level: false)
      200

      iex> Req.get!("http://api.github.com", redirect_log_level: :error)
      # 23:24:11.670 [error]  follow_redirects: redirecting to https://api.github.com/
      200

  """
  @doc step: :response
  def follow_redirects(request_response)

  def follow_redirects({request, response}) when request.options.follow_redirects == false do
    {request, response}
  end

  def follow_redirects({request, %{status: status} = response})
      when status in [301, 302, 303, 307, 308] do
    max_redirects = Map.get(request.options, :max_redirects, 10)
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
  end

  def follow_redirects(other) do
    other
  end

  defp build_redirect_request(request, response) do
    {_, location} = List.keyfind(response.headers, "location", 0)

    log_level = Map.get(request.options, :redirect_log_level, :debug)
    log_redirect(log_level, location)

    location_trusted = Map.get(request.options, :location_trusted)

    location_url = URI.merge(request.url, URI.parse(location))

    request
    |> remove_params()
    |> remove_credentials_if_untrusted(location_trusted, location_url)
    |> put_redirect_request_method(response.status)
    |> put_redirect_location(location_url)
  end

  defp log_redirect(false, _location), do: :ok

  defp log_redirect(level, location) do
    Logger.log(level, [
      "follow_redirects: redirecting to ",
      location
    ])
  end

  defp put_redirect_location(request, location_url) do
    put_in(request.url, location_url)
  end

  defp put_redirect_request_method(request, status) when status in 307..308, do: request

  defp put_redirect_request_method(request, _), do: %{request | method: :get}

  defp remove_credentials_if_untrusted(request, true, _), do: request

  defp remove_credentials_if_untrusted(request, _, location_url) do
    if {location_url.host, location_url.scheme, location_url.port} ==
         {request.url.host, request.url.scheme, request.url.port} do
      request
    else
      remove_credentials(request)
    end
  end

  defp remove_credentials(request) do
    headers = List.keydelete(request.headers, "authorization", 0)
    request = update_in(request.options, &Map.delete(&1, :auth))
    %{request | headers: headers}
  end

  defp remove_params(request) do
    update_in(request.options, &Map.delete(&1, :params))
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

        * `:safe` (default) - retry GET/HEAD requests on HTTP 408/429/5xx responses or exceptions

        * `fun` - a 1-arity function that accepts either a `Req.Response` or an exception struct
          and returns boolean whether to retry

        * `false` - never retry

    * `:retry_delay` - a function that receives the retry count (starting at 0) and returns the delay, the
      number of milliseconds to sleep before making another attempt.
      Defaults to a simple exponential backoff: 1s, 2s, 4s, 8s, ...

      If the response is HTTP 429 and contains the `retry-after` header, the value of the header is used to
      determine the next retry delay.

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
    case Map.get(request.options, :retry, :safe) do
      :safe ->
        if request.method in [:get, :head] do
          case response_or_exception do
            %Req.Response{status: status} when status in [408, 429] or status in 500..599 ->
              retry(request, response_or_exception)

            %Req.Response{} ->
              {request, response_or_exception}

            %{__exception__: true} ->
              retry(request, response_or_exception)
          end
        else
          {request, response_or_exception}
        end

      # TODO: Deprecate in v0.4
      :never ->
        {request, response_or_exception}

      false ->
        {request, response_or_exception}

      fun when is_function(fun) ->
        if fun.(response_or_exception) do
          retry(request, response_or_exception)
        else
          {request, response_or_exception}
        end

      other ->
        raise ArgumentError,
              "expected :retry to be :safe, false, or a 1-arity function, " <>
                "got: #{inspect(other)}"
    end
  end

  defp retry(request, response_or_exception) do
    retry_count = Req.Request.get_private(request, :req_retry_count, 0)
    {request, delay} = get_retry_delay(request, response_or_exception, retry_count)
    max_retries = Map.get(request.options, :max_retries, 3)
    log_level = Map.get(request.options, :retry_log_level, :error)

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

  defp get_retry_delay(request, %Req.Response{status: 429} = response, retry_count) do
    case Req.Response.get_header(response, "retry-after") do
      [delay] ->
        {request, retry_delay_in_ms(delay)}

      [] ->
        calculate_retry_delay(request, retry_count)
    end
  end

  defp get_retry_delay(request, _response, retry_count) do
    calculate_retry_delay(request, retry_count)
  end

  defp calculate_retry_delay(request, retry_count) do
    case Map.get(request.options, :retry_delay, &exp_backoff/1) do
      delay when is_integer(delay) ->
        {request, delay}

      fun when is_function(fun, 1) ->
        {request, fun.(retry_count)}
    end
  end

  defp exp_backoff(n) do
    Integer.pow(2, n) * 1000
  end

  defp retry_delay_in_ms(delay_value) do
    case Integer.parse(delay_value) do
      {seconds, ""} ->
        :timer.seconds(seconds)

      :error ->
        delay_value
        |> parse_http_datetime()
        |> DateTime.diff(DateTime.utc_now(), :millisecond)
        |> max(0)
    end
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

  defp get_content_encoding_header(headers) do
    headers
    |> Enum.flat_map(fn {name, value} ->
      if String.downcase(name) == "content-encoding" do
        value
        |> String.downcase()
        |> String.split(",", trim: true)
        |> Stream.map(&String.trim/1)
      else
        []
      end
    end)
    |> Enum.reverse()
  end

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

  @month_numbers %{
    "Jan" => "01",
    "Feb" => "02",
    "Mar" => "03",
    "Apr" => "04",
    "May" => "05",
    "Jun" => "06",
    "Jul" => "07",
    "Aug" => "08",
    "Sep" => "09",
    "Oct" => "10",
    "Nov" => "11",
    "Dec" => "12"
  }
  defp parse_http_datetime(datetime) do
    [_day_of_week, day, month, year, time, "GMT"] = String.split(datetime, " ")
    date = year <> "-" <> @month_numbers[month] <> "-" <> day

    case DateTime.from_iso8601(date <> " " <> time <> "Z") do
      {:ok, valid_datetime, 0} ->
        valid_datetime

      {:error, reason} ->
        raise "could not parse \"Retry-After\" header #{datetime} - #{reason}"
    end
  end
end
