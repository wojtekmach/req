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


  ## Request Options:

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
    put_new_header(request, "authorization", "Bearer #{token}")
  end

  defp auth(request, {username, password}) when is_binary(username) and is_binary(password) do
    value = Base.encode64("#{username}:#{password}")
    put_new_header(request, "authorization", "Basic #{value}")
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

  ## Examples

      iex> Req.get!("https://httpbin.org/user-agent").body
      %{"user-agent" => "#{@user_agent}"}
  """
  @doc step: :request
  def put_default_user_agent(request) do
    put_new_header(request, "user-agent", @user_agent)
  end

  @default_accept_encoding "gzip, deflate"

  @doc """
  Asks the server to return compressed response.

  ## Request Options

    * `:compressed` - if set to `true`, sets the `accept-encoding` header with compression
      algorithms that Req supports out of the box: `#{inspect(@default_accept_encoding)}`. Defaults
      to `true`.

  ## Examples

  Req automatically decompresses response body (`decompress/1` step) so let's disable that by
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

  """
  @doc step: :request
  def compressed(request) do
    case Map.fetch(request.options, :compressed) do
      :error ->
        put_new_header(request, "accept-encoding", @default_accept_encoding)

      {:ok, true} ->
        put_new_header(request, "accept-encoding", @default_accept_encoding)

      {:ok, false} ->
        request
    end
  end

  @doc """
  Encodes request headers.

  Turns atom header names into strings, replacing `-` with `_`. For example, `:user_agent` becomes
  `"user-agent"`. Non-atom header names are kept as is.

  If a header value is a `NaiveDateTime` or `DateTime`, it is encoded as "HTTP date". Otherwise,
  the header value is encoded with `String.Chars.to_string/1`.

  ## Examples

      iex> Req.get!("https://httpbin.org/user-agent", headers: [user_agent: :my_agent]).body
      %{"user-agent" => "my_agent"}

      iex> headers = [x_expires_at: ~N[2022-01-01 09:00:00]]
      iex> Req.get!("https://httpbin.org/headers", headers: headers).body["headers"]["X-Expires-At"]
      "Sat, 01 Jan 2022 09:00:00 GMT"

  """
  @doc step: :request
  def encode_headers(request) do
    headers =
      for {name, value} <- request.headers do
        name =
          case name do
            atom when is_atom(atom) ->
              atom |> Atom.to_string() |> String.replace("_", "-")

            binary when is_binary(binary) ->
              binary
          end

        value =
          case value do
            %NaiveDateTime{} = naive_datetime ->
              format_http_datetime(naive_datetime)

            %DateTime{} = datetime ->
              datetime |> DateTime.shift_zone!("Etc/UTC") |> format_http_datetime()

            _ ->
              String.Chars.to_string(value)
          end

        {name, value}
      end

    %{request | headers: headers}
  end

  @doc """
  Encodes the request body based on its shape.

  If body is of the following shape, it's encoded and its `content-type` set
  accordingly. Otherwise it's unchanged.

  | Shape           | Encoder                     | Content-Type                          |
  | --------------- | --------------------------- | ------------------------------------- |
  | `{:form, data}` | `URI.encode_query/1`        | `"application/x-www-form-urlencoded"` |
  | `{:json, data}` | `Jason.encode_to_iodata!/1` | `"application/json"`                  |

  ## Examples

      iex> Req.post!("https://httpbin.org/post", body: {:form, comments: "hello!"}).body["form"]
      %{"comments" => "hello!"}

  """
  @doc step: :request
  def encode_body(request) do
    case request.body do
      {:form, data} ->
        request
        |> Map.put(:body, URI.encode_query(data))
        |> put_new_header("content-type", "application/x-www-form-urlencoded")

      {:json, data} ->
        request
        |> Map.put(:body, Jason.encode_to_iodata!(data))
        |> put_new_header("content-type", "application/json")

      _other ->
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
    put_header(request, "range", range)
  end

  def put_range(%{options: %{range: first..last}} = request) do
    put_header(request, "range", "bytes=#{first}-#{last}")
  end

  def put_range(request) do
    request
  end

  @doc """
  Handles HTTP cache using `if-modified-since` header.

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
  def put_if_modified_since(request) do
    if request.options[:cache] do
      dir = Map.get(request.options, :cache_dir) || :filename.basedir(:user_cache, 'req')

      request
      |> do_put_if_modified_since(dir)
      |> Req.Request.prepend_response_steps([&handle_cache(&1, dir)])
    else
      request
    end
  end

  defp do_put_if_modified_since(request, dir) do
    case File.stat(cache_path(dir, request)) do
      {:ok, stat} ->
        datetime = stat.mtime |> NaiveDateTime.from_erl!() |> format_http_datetime()
        put_new_header(request, "if-modified-since", datetime)

      _ ->
        request
    end
  end

  defp handle_cache({request, response}, dir) do
    cond do
      response.status == 200 ->
        write_cache(dir, request, response)
        {request, response}

      response.status == 304 ->
        response = load_cache(dir, request)
        {request, response}

      true ->
        {request, response}
    end
  end

  @doc """
  Runs the request using `Finch`.

  This is the default Req _adapter_. See `:adapter` field description in the `Req.Request` module
  documentation for more information on adapters.

  ## Request Options

    * `:finch` - the name of the Finch pool. Defaults to `Req.Finch` which is automatically
      started by Req.

    * `:finch_options` - options passed down to Finch when making the request, defaults to `[]`.
       See `Finch.request/3` for a list of available options.

    * `:unix_socket` - if set, connect through the given UNIX domain socket

  ## Examples

  Custom `:receive_timeout`:

      Req.get!(url: url, finch_options: [receive_timeout: 1000])

  Connecting through UNIX socket:

      iex> Req.get!("http:///v1.41/_ping", unix_socket: "/var/run/docker.sock").body
      "OK"

  """
  @doc step: :request
  def run_finch(request) do
    finch_request =
      Finch.build(request.method, request.url, request.headers, request.body)
      |> Map.replace!(:unix_socket, request.options[:unix_socket])

    finch_name = Map.get(request.options, :finch, Req.Finch)
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

  ## Request Options:

    * `:plug` - if set, the plug to run the request against.

  ## Examples

  Let's run the request against `Plug.Static` pointed to the Req's source code and
  fetch the README:

      iex> resp = Req.get!("http:///README.md", plug: {Plug.Static, at: "/", from: "."})
      iex> resp.body =~ "Req is an HTTP client"
      true
  """
  @doc step: :request
  def put_plug(request) do
    if request.options[:plug] do
      %{request | adapter: &Req.Steps.__run_plug__/1}
    else
      request
    end
  end

  def __run_plug__(request) do
    {plug, plug_options} =
      case Map.fetch(request.options, :plug) do
        {:ok, module} when is_atom(module) ->
          {module, []}

        {:ok, {module, options}} when is_atom(module) ->
          {module, options}

        :error ->
          raise "run_plug/1 requires :plug option to be set"
      end

    conn =
      Plug.Test.conn(request.method, request.url, request.body)
      |> Map.replace!(:req_headers, request.headers)
      |> plug.call(plug.init(plug_options))

    response = %Req.Response{
      status: conn.status,
      headers: conn.resp_headers,
      body: conn.resp_body
    }

    {request, response}
  end

  ## Response steps

  @doc """
  Decompresses the response body based on the `content-encoding` header.

  ## Examples

      iex> response = Req.get!("https://httpbin.org/gzip")
      iex> response.headers |> Enum.member?({"content-encoding", "gzip"})
      true
      iex> response.body["gzipped"]
      true
  """
  @doc step: :response
  def decompress(request_response)

  def decompress({request, %{body: ""} = response}) do
    {request, response}
  end

  def decompress({request, response}) when request.options.raw == true do
    {request, response}
  end

  def decompress({request, response}) do
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
  Decodes response body based on the detected format.

  Supported formats:

  | Format | Decoder                                                          |
  | ------ | ---------------------------------------------------------------- |
  | json   | `Jason.decode!/1`                                                |
  | gzip   | `:zlib.gunzip/1`                                                 |
  | tar    | `:erl_tar.extract/2`                                             |
  | zip    | `:zip.unzip/2`                                                   |
  | csv    | `NimbleCSV.RFC4180.parse_string/2` (if `NimbleCSV` is installed) |

  ## Examples

      iex> response = Req.get!("https://httpbin.org/gzip")
      ...> response.body["gzipped"]
      true

      iex> response = Req.get!("https://httpbin.org/json")
      ...> response.body["slideshow"]["title"]
      "Sample Slide Show"

  """
  @doc step: :response
  def decode_body(request_response)

  def decode_body({request, %{body: ""} = response}) do
    {request, response}
  end

  def decode_body({request, response}) when request.options.raw == true do
    {request, response}
  end

  def decode_body({request, response}) do
    case format(request, response) do
      "json" ->
        {request, update_in(response.body, &Jason.decode!/1)}

      "gz" ->
        {request, update_in(response.body, &:zlib.gunzip/1)}

      "tar" ->
        {:ok, files} = :erl_tar.extract({:binary, response.body}, [:memory])
        {request, put_in(response.body, files)}

      "tgz" ->
        {:ok, files} = :erl_tar.extract({:binary, response.body}, [:memory, :compressed])
        {request, put_in(response.body, files)}

      "zip" ->
        {:ok, files} = :zip.extract(response.body, [:memory])
        {request, put_in(response.body, files)}

      "csv" ->
        if nimble_csv_loaded?() do
          options = [skip_headers: false]
          {request, update_in(response.body, &NimbleCSV.RFC4180.parse_string(&1, options))}
        else
          {request, response}
        end

      _ ->
        {request, response}
    end
  end

  defp format(request, response) do
    with {_, content_type} <- List.keyfind(response.headers, "content-type", 0) do
      case extensions(content_type, request) do
        [ext | _] -> ext
        [] -> nil
      end
    end
  end

  defp extensions("application/octet-stream", request) do
    path = request.url.path

    if tgz?(path) do
      ["tgz"]
    else
      path |> MIME.from_path() |> MIME.extensions()
    end
  end

  defp extensions("application/" <> subtype, request) when subtype in ~w(gzip x-gzip) do
    path = request.url.path

    if tgz?(path) do
      ["tgz"]
    else
      ["gz"]
    end
  end

  defp extensions(content_type, _request) do
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

    * `:location_trusted` - by default, authorization credentials are only sent
      on redirects to the same host. If `:location_trusted` is set to `true`, credentials
      will be sent to any host.

  ## Examples

      iex> Req.get!("http://api.github.com").status
      # 23:24:11.670 [debug]  follow_redirects: redirecting to https://api.github.com/
      200

  """
  @doc step: :response
  def follow_redirects(request_response)

  def follow_redirects({request, %{status: status} = response})
      when status in [301, 302, 303, 307, 308] do
    {_, location} = List.keyfind(response.headers, "location", 0)
    Logger.debug(["follow_redirects: redirecting to ", location])

    location_trusted = Map.get(request.options, :location_trusted)
    location_url = URI.parse(location)

    request =
      request
      |> remove_credentials_if_untrusted(location_trusted, location_url)
      |> put_redirect_request_method()
      |> put_redirect_location(location_url)

    {_, result} = Req.Request.run(request)
    {Req.Request.halt(request), result}
  end

  def follow_redirects(other) do
    other
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
    if location_url.host == request.url.host do
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

  ## Error steps

  @doc """
  Retries a request in face of errors.

  This function can be used as either or both response and error step. It retries a request that
  resulted in:

    * a response with status 5xx

    * an exception

  ## Request Options

    * `:retry` - if `false`, disables automatic retries. Defaults to `true`.

    * `:request_delay` - sleep this number of milliseconds before making another attempt, defaults
      to `2000`

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

  def retry({request, %Req.Response{} = response}) when response.status < 500 do
    {request, response}
  end

  def retry({request, response_or_exception}) when request.options.retry == false do
    {request, response_or_exception}
  end

  def retry({request, response_or_exception}) do
    delay = Map.get(request.options, :retry_delay, 2000)
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

  defp put_new_header(struct, name, value) do
    if Enum.any?(struct.headers, fn {key, _} -> String.downcase(key) == name end) do
      struct
    else
      put_header(struct, name, value)
    end
  end

  defp put_header(struct, name, value) do
    update_in(struct.headers, &[{name, value} | &1])
  end

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
    Path.join(cache_dir, cache_key(request))
  end

  defp write_cache(cache_dir, request, response) do
    path = cache_path(cache_dir, request)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, :erlang.term_to_binary(response))
  end

  defp load_cache(cache_dir, request) do
    path = cache_path(cache_dir, request)
    path |> File.read!() |> :erlang.binary_to_term()
  end

  defp cache_key(request) do
    hash =
      :crypto.hash(:sha256, :erlang.term_to_binary(request.url))
      |> Base.encode16(case: :lower)

    request.url.host <> "-" <> hash
  end

  defp format_http_datetime(datetime) do
    Calendar.strftime(datetime, "%a, %d %b %Y %H:%M:%S GMT")
  end
end
