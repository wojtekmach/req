defmodule Req.Steps do
  @moduledoc """
  A collection of built-in steps.
  """

  require Logger

  ## Request steps

  @doc """
  Adds default steps.

  ## Request steps

    * `encode_headers/1`

    * `put_default_headers/1`

    * `encode_body/1`

    * [`&put_base_url(&1, options[:base_url])`](`base_url/2`) (if `options[:base_url]` is set)

    * [`&auth(&1, options[:auth])`](`auth/2`) (if `options[:auth]` is set)

    * [`&put_params(&1, options[:params])`](`put_params/2`) (if `options[:params]` is set)

    * [`&put_range(&1, options[:range])`](`put_range/2`) (if `options[:range]` is set)

    * [`&run_steps(&1, options[:steps])`](`run_steps/2`) (if `options[:steps]` is set)

  ## Response steps

    * [`&retry(&1, options[:retry])`](`retry/2`) (if `options[:retry]` is set to
      an atom true or a options keywords list)

    * [`&follow_redirects(&1, options[:follow_redirects])`](`follow_redirects/2`)

    * `decompress/1`

    * `decode_body/1`

  ## Error steps

    * [`&retry(&1, options[:retry])`](`retry/2`) (if `options[:retry]` is set and is a
      keywords list or an atom `true`)

  ## Options

    * `:base_url` - if set, adds the `put_base_url/2` step

    * `:auth` - if set, adds the `auth/2` step

    * `:params` - if set, adds the `put_params/2` step

    * `:range` - if set, adds the `put_range/2` step

    * `:cache` - if set to `true`, adds `put_if_modified_since/2` step

    * `:raw` if set to `true`, skips `decompress/1` and `decode_body/1` steps

    * `:retry` - if set, adds the `retry/2` step to response and error steps

    * `:steps` - if set, runs the `run_steps/2` step with the given steps

    * `:follow_redirects` - if set, runs the `follow_redirect/2` step with the given list
       of options

  """
  @doc step: :request
  def put_default_steps(request, options \\ []) do
    request_steps =
      [
        {Req.Steps, :encode_headers, []},
        {Req.Steps, :put_default_headers, []},
        {Req.Steps, :encode_body, []}
      ] ++
        maybe_steps(options[:base_url], [{Req.Steps, :put_base_url, [options[:base_url]]}]) ++
        maybe_steps(options[:auth], [{Req.Steps, :auth, [options[:auth]]}]) ++
        maybe_steps(options[:params], [{Req.Steps, :put_params, [options[:params]]}]) ++
        maybe_steps(options[:range], [{Req.Steps, :put_range, [options[:range]]}]) ++
        maybe_steps(options[:cache], [{Req.Steps, :put_if_modified_since, []}]) ++
        maybe_steps(options[:steps], [{Req.Steps, :run_steps, [options[:steps]]}])

    retry = options[:retry]
    retry = if retry == true, do: [], else: retry

    raw? = options[:raw] == true

    response_steps =
      maybe_steps(retry, [{Req.Steps, :retry, [retry]}]) ++
        [{Req.Steps, :follow_redirects, [options[:follow_redirects]]}] ++
        maybe_steps(not raw?, [
          {Req.Steps, :decompress, []},
          {Req.Steps, :decode_body, []}
        ])

    error_steps = maybe_steps(retry, [{Req.Steps, :retry, [retry]}])

    request
    |> Req.Request.append_request_steps(request_steps)
    |> Req.Request.append_response_steps(response_steps)
    |> Req.Request.append_error_steps(error_steps)
  end

  defp maybe_steps(nil, _step), do: []
  defp maybe_steps(false, _step), do: []
  defp maybe_steps(_, steps), do: steps

  @doc """
  Sets base URL for all requests.

  Note this step would overwrite existing base_url, see examples below:

  ## Examples

      iex> options = [base_url: "https://httpbin.org"]
      iex> Req.get!("/status/200", options).status
      200
      iex> Req.get!("/status/201", options).status
      201
      iex> Req.get!("https://unknown-host/status/201", options).status
      201
  """
  @doc step: :request
  def put_base_url(request, base_url) when is_binary(base_url) do
    # TODO: change build/3 so that the url is parsed later so that here it is not yet parsed

    # remove when we require Elixir v1.13
    url = request.url.path || ""

    url = URI.parse(base_url <> url)
    %{request | url: url}
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
  def auth(request, auth)

  def auth(request, {:bearer, token}) when is_binary(token) do
    put_new_header(request, "authorization", "Bearer #{token}")
  end

  def auth(request, {username, password}) when is_binary(username) and is_binary(password) do
    value = Base.encode64("#{username}:#{password}")
    put_new_header(request, "authorization", "Basic #{value}")
  end

  def auth(request, :netrc) do
    path = System.get_env("NETRC") || Path.join(System.user_home!(), ".netrc")
    authenticate_with_netrc(request, path)
  end

  def auth(request, {:netrc, path}) do
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
  Adds common request headers.

  Currently the following headers are added:

    * `"user-agent"` - `#{inspect(@user_agent)}`

    * `"accept-encoding"` - `"gzip"`

  """
  @doc step: :request
  def put_default_headers(request) do
    request
    |> put_new_header("user-agent", @user_agent)
    |> put_new_header("accept-encoding", "gzip")
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

      iex> Req.post!("https://httpbin.org/post", {:form, comments: "hello!"}).body["form"]
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

  ## Examples

      iex> Req.get!("https://httpbin.org/anything/query", params: [x: "1", y: "2"]).body["args"]
      %{"x" => "1", "y" => "2"}

  """
  @doc step: :request
  def put_params(request, params) do
    encoded = URI.encode_query(params)

    update_in(request.url.query, fn
      nil -> encoded
      query -> query <> "&" <> encoded
    end)
  end

  @doc """
  Sets the "Range" request header.

  `range` can be one of the following:

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
  def put_range(request, range)

  def put_range(request, binary) when is_binary(binary) do
    put_header(request, "range", binary)
  end

  def put_range(request, first..last) do
    put_header(request, "range", "bytes=#{first}-#{last}")
  end

  @doc """
  Handles HTTP cache using `if-modified-since` header.

  Only successful (200 OK) responses are cached.

  This step also _prepends_ a response step that loads and writes the cache. Be careful when
  _prepending_ other response steps, make sure the cache is loaded/written as soon as possible.

  ## Options

    * `:dir` - the directory to store the cache, defaults to `<user_cache_dir>/req`
      (see: `:filename.basedir/3`)

  ## Examples

      iex> url = "https://httpbin.org/html"
      iex> response1 = Req.get!(url, cache: true)
      iex> response2 = Req.get!(url, cache: true)
      iex> response1 == response2
      true

  """
  @doc step: :request
  def put_if_modified_since(request, options \\ []) do
    dir = options[:dir] || :filename.basedir(:user_cache, 'req')

    request
    |> do_put_if_modified_since(dir)
    |> Req.Request.prepend_response_steps([&handle_cache(&1, dir)])
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
  Runs the given steps.

  A step is a function that takes and returns a usually updated `state`.
  The `state` is:

    * a `request` struct for request steps

    * a `{request, response}` tuple for response steps

    * a `{request, exception}` tuple for error steps

  A step can be one of the following:

    * a 1-arity function

    * a `{module, function, args}` tuple - calls `apply(module, function, [state | args])`

    * a `{module, options}` tuple - calls `module.run(state, options)`

    * a `module` atom - calls `module.run(state, [])`

  ## Examples

      iex> inspect_host = fn request -> IO.inspect(request.url.host) ; request end
      iex> Req.get!("https://httpbin.org/status/200", steps: [inspect_host]).status
      # Outputs: "httpbin.org"
      200

  """
  @doc step: :request
  def run_steps(request, steps) when is_list(steps) do
    Enum.reduce(steps, request, &Req.Request.run_step/2)
  end

  @doc """
  Runs the request using `Finch`.

  This is the default adapter. See `Req.Request.put_adapter/2` for more information.
  """
  @doc step: :request
  def run_finch(request) do
    finch_request =
      Finch.build(request.method, request.url, request.headers, request.body)
      |> Map.replace!(:unix_socket, request.unix_socket)

    {finch_name, finch_options} = request.private.req_finch

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
        if Code.ensure_loaded?(NimbleCSV) do
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

  ## Options

    * `:location_trusted` - by default, authorization credentials are only sent
      on redirects to the same host. If `:location_trusted` is set to `true`, credentials
      will be sent to any host.

  ## Examples

      iex> Req.get!("http://api.github.com").status
      # 23:24:11.670 [debug]  Req.follow_redirects/2: Redirecting to https://api.github.com/
      200

  """
  @doc step: :response
  def follow_redirects(request_response, options \\ [])

  def follow_redirects({request, %{status: status} = response}, options)
      when status in [301, 302, 303, 307, 308] do
    {_, location} = List.keyfind(response.headers, "location", 0)
    Logger.debug(["Req.follow_redirects/2: Redirecting to ", location])

    location_trusted = options[:location_trusted]
    location_url = URI.parse(location)

    request =
      request
      |> remove_credentials_if_untrusted(location_trusted, location_url)
      |> put_redirect_request_method()
      |> put_redirect_location(location_url)

    {_, result} = Req.Request.run(request)
    {Req.Request.halt(request), result}
  end

  def follow_redirects(other, _) do
    other
  end

  ## Error steps

  @doc """
  Retries a request in face of errors.

  This function can be used as either or both response and error step. It retries a request that
  resulted in:

    * a response with status 5xx

    * an exception

  ## Options

    * `:delay` - sleep this number of milliseconds before making another attempt, defaults
      to `2000`

    * `:max_retries` - maximum number of retry attempts, defaults to `2` (for a total of `3`
      requests to the server, including the initial one.)

  ## Examples

  With default options:

      iex> Req.get!("https://httpbin.org/status/500,200", retry: true).status
      # 19:02:08.463 [error] Req.retry/3: Got response with status 500. Will retry in 2000ms, 2 attempts left
      # 19:02:10.710 [error] Req.retry/3: Got response with status 500. Will retry in 2000ms, 1 attempt left
      200

  With custom options:

      iex> Req.get!("http://localhost:9999", retry: [delay: 100, max_retries: 3])
      # 17:00:38.371 [error] Req.retry/3: Got exception. Will retry in 100ms, 3 attempts left
      # 17:00:38.371 [error] ** (Mint.TransportError) connection refused
      # 17:00:38.473 [error] Req.retry/3: Got exception. Will retry in 100ms, 2 attempts left
      # 17:00:38.473 [error] ** (Mint.TransportError) connection refused
      # 17:00:38.575 [error] Req.retry/3: Got exception. Will retry in 100ms, 1 attempt left
      # 17:00:38.575 [error] ** (Mint.TransportError) connection refused
      ** (Mint.TransportError) connection refused

  """
  @doc step: :error
  def retry(request_response_or_error, options)

  def retry({request, %{status: status} = response}, _options) when status < 500 do
    {request, response}
  end

  def retry({request, response_or_exception}, options) when is_list(options) do
    delay = Keyword.get(options, :delay, 2000)
    max_retries = Keyword.get(options, :max_retries, 2)
    retry_count = Req.Request.get_private(request, :retry_count, 0)

    if retry_count < max_retries do
      log_retry(response_or_exception, retry_count, max_retries, delay)
      Process.sleep(delay)
      request = Req.Request.put_private(request, :retry_count, retry_count + 1)

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

    message = ["Will retry in #{delay}ms, ", retries_left, " left"]

    case response_or_exception do
      %{__exception__: true} = exception ->
        Logger.error([
          "Req.retry/3: Got exception. ",
          message
        ])

        Logger.error([
          "** (#{inspect(exception.__struct__)}) ",
          Exception.message(exception)
        ])

      response ->
        Logger.error(["Req.retry/3: Got response with status #{response.status}. ", message])
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
    request_steps = Enum.reject(request.request_steps, fn {_, step, _} -> step == :auth end)

    %{request | headers: headers, request_steps: request_steps}
  end
end
