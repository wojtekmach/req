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

    * `:base_url` - if set, the request URL is prepended with this base URL.
      If request URL contains a scheme, base URL is ignored.

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
    if request.url.scheme do
      request
    else
      # remove when we require Elixir v1.13
      url = request.url.path || ""

      url = URI.parse(base_url <> url)
      %{request | url: url}
    end
  end

  def put_base_url(request) do
    request
  end

  @doc """
  Sets request authentication.

  `auth` can be one of:

    * `{username, password}` - uses Basic HTTP authentication

    * `{:bearer, token}` - uses Bearer HTTP authentication

    * `:netrc` - load credentials from `.netrc` at path specified in `NETRC` environment variable;
      if `NETRC` is not set, load `.netrc` in user's home directory

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
      iex> response.headers |> List.keyfind("content-encoding", 0)
      {"content-encoding", "gzip"}
      iex> response.body |> binary_part(0, 2)
      <<31, 139>>

  Now, let's pass `compressed: false` and notice the raw body was not compressed:

      iex> response = Req.get!("https://elixir-lang.org", raw: true, compressed: false)
      iex> response.headers |> List.keyfind("content-encoding", 0)
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
    value = "gzip, deflate"
    value = if brotli_loaded?(), do: "br, " <> value, else: value
    if ezstd_loaded?(), do: "zstd, " <> value, else: value
  end

  @doc """
  Encodes the request body.

  ## Request Options

    * `:form` - if set, encodes the request body as form data (using `URI.encode_query/1`).

    * `:json` - if set, encodes the request body as JSON (using `Jason.encode_to_iodata!/1`).

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

      true ->
        request
    end
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
      iex> List.keyfind(response.headers, "content-range", 0)
      {"content-range", "bytes 0-3/100"}
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
      dir = Map.get(request.options, :cache_dir) || :filename.basedir(:user_cache, 'req')
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
        datetime = stat.mtime |> NaiveDateTime.from_erl!() |> format_http_datetime()
        Req.Request.put_new_header(request, "if-modified-since", datetime)

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
      This option takes precedence over `:http2` option mentioned below.

    * `:finch_options` - options passed down to Finch when making the request, defaults to `[]`.
       See `Finch.request/3` for a list of available options.

    * `:http2` - if `true`, uses an HTTP/2 pool automatically started by Req.

    * `:unix_socket` - if set, connect through the given UNIX domain socket

  ## Examples

  Custom `:receive_timeout`:

      iex> Req.get!(url: url, finch_options: [receive_timeout: 1000])

  Connecting through UNIX socket:

      iex> Req.get!("http:///v1.41/_ping", unix_socket: "/var/run/docker.sock").body
      "OK"

  """
  @doc step: :request
  def run_finch(request) do
    finch_request =
      Finch.build(request.method, request.url, request.headers, request.body)
      |> Map.replace!(:unix_socket, request.options[:unix_socket])

    finch_name =
      case Map.fetch(request.options, :finch) do
        {:ok, name} ->
          name

        :error ->
          cond do
            request.options[:http2] ->
              Req.FinchHTTP2

            true ->
              Req.FinchHTTP1
          end
      end

    finch_options = Map.get(request.options, :finch_options, [])

    case Finch.request(finch_request, finch_name, finch_options) do
      {:ok, response} ->
        response = %Req.Response{
          status: response.status,
          headers: response.headers,
          body: response.body
        }

        {request, response}

      {:error, exception} ->
        {request, exception}
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

  Here is the same example but with plug as an anonymous function:

      test "echo" do
        echo = fn conn ->
          "/" <> path = conn.request_path
          Plug.Conn.send_resp(conn, 200, path)
        end

        assert Req.get!("http:///hello", plug: echo).body == "hello"
      end

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
    body = IO.iodata_to_binary(request.body)

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
  | zip           | `:zlib.unzip/1`                                 |
  | br            | `:brotli.decode/1` (if [brotli] is installed)   |
  | zstd          | `:ezstd.decompress/1` (if [ezstd] is installed) |

  ## Examples

      iex> response = Req.get!("https://httpbin.org/gzip")
      iex> response.headers |> List.keyfind("content-encoding", 0)
      {"content-encoding", "gzip"}
      iex> response.body["gzipped"]
      true

  If the [brotli] package is installed, Brotli is also supported:

      Mix.install([
        :req,
        {:brotli, "~> 0.3.0"}
      ])

      response = Req.get!("https://httpbin.org/brotli")
      response.headers |> List.keyfind("content-encoding", 0)
      #=> {"content-encoding", "br"}
      response.body["brotli"]
      #=> true

  [brotli]: http://hex.pm/packages/brotli
  [ezstd]: https://hex.pm/packages/ezstd
  """
  @doc step: :response
  def decompress_body(request_response)

  def decompress_body({request, %{body: ""} = response}) do
    {request, response}
  end

  def decompress_body({request, response}) when request.options.raw == true do
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
    if Code.ensure_loaded?(NimbleCSV) do
      true
    else
      quote do
        Code.ensure_loaded?(NimbleCSV)
      end
    end
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
  | json     | `Jason.decode!/1`                                                 |
  | gzip     | `:zlib.gunzip/1`                                                  |
  | tar, tgz | `:erl_tar.extract/2`                                              |
  | zip      | `:zip.unzip/2`                                                    |
  | csv      | `NimbleCSV.RFC4180.parse_string/2` (if [nimble_csv] is installed) |

  ## Request Options

    * `:decode_body` - if set to `false`, disables automatic response body decoding.
      Defaults to `true`.

  ## Examples

      iex> response = Req.get!("https://httpbin.org/gzip")
      ...> response.body["gzipped"]
      true

      iex> response = Req.get!("https://httpbin.org/json")
      ...> response.body["slideshow"]["title"]
      "Sample Slide Show"

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

  defp decode_body({request, response}, "json") do
    {request, update_in(response.body, &Jason.decode!/1)}
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

  defp decode_body({request, response}, _) do
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
      If the limit is reached, an erorr is raised.


  ## Examples

      iex> Req.get!("http://api.github.com").status
      # 23:24:11.670 [debug]  follow_redirects: redirecting to https://api.github.com/
      200

      iex> Req.get!("https://httpbin.org/redirect/4", max_redirects: 3)
      # 23:07:59.570 [debug] follow_redirects: redirecting to /relative-redirect/3
      # 23:08:00.068 [debug] follow_redirects: redirecting to /relative-redirect/2
      # 23:08:00.206 [debug] follow_redirects: redirecting to /relative-redirect/1
      ** (RuntimeError) too many redirects (3)

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
    Logger.debug(["follow_redirects: redirecting to ", location])

    location_trusted = Map.get(request.options, :location_trusted)
    location_url = URI.parse(location)

    request
    |> remove_params()
    |> remove_credentials_if_untrusted(location_trusted, location_url)
    |> put_redirect_request_method()
    |> put_redirect_location(location_url)
  end

  defp put_redirect_location(request, location_url) do
    if location_url.host do
      put_in(request.url, location_url)
    else
      update_in(request.url, &%{&1 | path: location_url.path, query: location_url.query})
    end
  end

  defp put_redirect_request_method(request) when request.status in 307..308, do: request

  defp put_redirect_request_method(request), do: %{request | method: :get}

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

  @default_retry_delay 2000

  @doc """
  Retries a request in face of errors.

  This function can be used as either or both response and error step.

  ## Request Options

    * `:retry` - can be one of the following:

        * `:safe` (default) - retry GET/HEAD requests on HTTP 408/429/5xx responses or exceptions

        * `:always` - always retry

        * `:never` - never retry

        * `fun` - a 1-arity function that accepts either a `Req.Response` or an exception struct
          and returns boolean whether to retry

    * `:retry_delay` - sleep this number of milliseconds before making another attempt, defaults
      to `#{@default_retry_delay}`. If the response is HTTP 429 and contains the `retry-after`
      header, the value of the header is used as the next retry delay.

    * `:max_retries` - maximum number of retry attempts, defaults to `2` (for a total of `3`
      requests to the server, including the initial one.)

  ## Examples

  With default options:

      iex> Req.get!("https://httpbin.org/status/500,200").status
      # 19:02:08.463 [error] retry: got response with status 500, will retry in 2000ms, 2 attempts left
      # 19:02:10.710 [error] retry: got response with status 500, will retry in 2000ms, 1 attempt left
      200

  With custom options:

      iex> Req.get!("http://localhost:9999", retry_delay: 100, max_retries: 3)
      # 17:00:38.371 [error] retry: got exception, will retry in 100ms, 3 attempts left
      # 17:00:38.371 [error] ** (Mint.TransportError) connection refused
      # 17:00:38.473 [error] retry: got exception, will retry in 100ms, 2 attempts left
      # 17:00:38.473 [error] ** (Mint.TransportError) connection refused
      # 17:00:38.575 [error] retry: got exception, will retry in 100ms, 1 attempt left
      # 17:00:38.575 [error] ** (Mint.TransportError) connection refused
      ** (Mint.TransportError) connection refused

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

      :always ->
        retry(request, response_or_exception)

      :never ->
        {request, response_or_exception}

      fun when is_function(fun) ->
        if fun.(response_or_exception) do
          retry(request, response_or_exception)
        else
          {request, response_or_exception}
        end

      other ->
        raise ArgumentError,
              "expected :retry to be :safe, :always, :never or a 1-arity function, " <>
                "got: #{inspect(other)}"
    end
  end

  defp retry(request, response_or_exception) do
    delay = get_retry_delay(request, response_or_exception)
    max_retries = Map.get(request.options, :max_retries, 2)
    retry_count = Req.Request.get_private(request, :req_retry_count, 0)

    if retry_count < max_retries do
      log_retry(response_or_exception, retry_count, max_retries, delay)
      Process.sleep(delay)
      request = Req.Request.put_private(request, :req_retry_count, retry_count + 1)

      {_, result} = Req.Request.run(request)
      {Req.Request.halt(request), result}
    else
      {request, response_or_exception}
    end
  end

  defp get_retry_delay(request, %Req.Response{status: 429} = response) do
    case List.keyfind(response.headers, "retry-after", 0) do
      {_, header_delay} ->
        retry_delay_in_ms(header_delay)

      nil ->
        Map.get(request.options, :retry_delay, @default_retry_delay)
    end
  end

  defp get_retry_delay(request, _response_or_exception) do
    Map.get(request.options, :retry_delay, @default_retry_delay)
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

  defp log_retry(response_or_exception, retry_count, max_retries, delay) do
    retries_left =
      case max_retries - retry_count do
        1 -> "1 attempt"
        n -> "#{n} attempts"
      end

    message = ["will retry in #{delay}ms, ", retries_left, " left"]

    case response_or_exception do
      %{__exception__: true} = exception ->
        Logger.error([
          "retry: got exception, ",
          message
        ])

        Logger.error([
          "** (#{inspect(exception.__struct__)}) ",
          Exception.message(exception)
        ])

      response ->
        Logger.error(["retry: got response with status #{response.status}, ", message])
    end
  end

  ## Utilities

  defp get_content_encoding_header(headers) do
    if value = get_header(headers, "content-encoding") do
      value
      |> String.downcase()
      |> String.split(",", trim: true)
      |> Stream.map(&String.trim/1)
      |> Enum.reverse()
    else
      []
    end
  end

  defp get_header(headers, name) do
    Enum.find_value(headers, nil, fn {key, value} ->
      if String.downcase(key) == name do
        value
      else
        nil
      end
    end)
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
