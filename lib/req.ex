defmodule Req do
  require Logger

  @external_resource "README.md"

  @moduledoc "README.md"
             |> File.read!()
             |> String.split("<!-- MDOC !-->")
             |> Enum.fetch!(1)

  @type url() :: URI.t() | String.t()

  @type method() :: :get | :post | :put | :delete

  @doc """
  Makes a GET request.

  See `request/3` for a list of supported options.
  """
  @doc api: :high_level
  @spec get!(url(), keyword()) :: Req.Response.t()
  def get!(url, options \\ []) do
    request!(:get, url, options)
  end

  @doc """
  Makes a POST request.

  See `request/3` for a list of supported options.
  """
  @doc api: :high_level
  @spec post!(url(), body :: term(), keyword()) :: Req.Response.t()
  def post!(url, body, options \\ []) do
    options = Keyword.put(options, :body, body)
    request!(:post, url, options)
  end

  @doc """
  Makes a PUT request.

  See `request/3` for a list of supported options.
  """
  @doc api: :high_level
  @spec put!(url(), body :: term(), keyword()) :: Req.Response.t()
  def put!(url, body, options \\ []) do
    options = Keyword.put(options, :body, body)
    request!(:put, url, options)
  end

  @doc """
  Makes a DELETE request.

  See `request/3` for a list of supported options.
  """
  @doc api: :high_level
  @spec delete!(url(), keyword()) :: Req.Response.t()
  def delete!(url, options \\ []) do
    request!(:delete, url, options)
  end

  @doc """
  Makes an HTTP request.

  ## Options

    * `:headers` - request headers, defaults to `[]`

    * `:body` - request body, defaults to `""`

    * `:finch` - Finch pool to use, defaults to `Req.Finch` which is automatically started
      by the application. See `Finch` module documentation for more information on starting pools.

    * `:finch_options` - Options passed down to Finch when making the request, defaults to `[]`.
      See `Finch.request/3` for more information.

  The `options` are passed down to `put_default_steps/2`, see its documentation for more
  information how they are being used.

  The `options` are merged with default options set with `default_options/1`.
  """
  @doc api: :high_level
  @spec request(method(), url(), keyword()) ::
          {:ok, Req.Response.t()} | {:error, Exception.t()}
  def request(method, url, options \\ []) do
    options = Keyword.merge(default_options(), options)

    method
    |> build(url, options)
    |> put_default_steps(options)
    |> run()
  end

  @doc """
  Makes an HTTP request and returns a response or raises an error.

  See `request/3` for more information.
  """
  @doc api: :high_level
  @spec request!(method(), url(), keyword()) :: Req.Response.t()
  def request!(method, url, options \\ []) do
    options = Keyword.merge(default_options(), options)

    method
    |> build(url, options)
    |> put_default_steps(options)
    |> run!()
  end

  @doc """
  Returns default options.

  See `default_options/1` for more information.
  """
  @doc api: :high_level
  @spec default_options() :: keyword()
  def default_options() do
    Application.get_env(:req, :default_options, [])
  end

  @doc """
  Sets default options.

  The default options are used by `get!/2`, `post!/3`, `put!/3`,
  `delete!/2`, `request/3`, and `request!/3` functions.

  Avoid setting default options in libraries as they are global.
  """
  @doc api: :high_level
  @spec default_options(keyword()) :: :ok
  def default_options(options) do
    Application.put_env(:req, :default_options, options)
  end

  ## Low-level API

  @doc """
  Builds a request pipeline.

  ## Options

    * `:header` - request headers, defaults to `[]`

    * `:body` - request body, defaults to `""`

    * `:finch` - Finch pool to use, defaults to `Req.Finch` which is automatically started
      by the application. See `Finch` module documentation for more information on starting pools.

    * `:finch_options` - Options passed down to Finch when making the request, defaults to `[]`.
      See `Finch.request/3` for more information.

  """
  @doc api: :low_level
  def build(method, url, options \\ []) do
    %Req.Request{
      method: method,
      url: URI.parse(url),
      headers: Keyword.get(options, :headers, []),
      body: Keyword.get(options, :body, ""),
      unix_socket: Keyword.get(options, :unix_socket),
      private: %{
        req_finch:
          {Keyword.get(options, :finch, Req.Finch), Keyword.get(options, :finch_options, [])}
      }
    }
  end

  @doc """
  Appends request steps.
  """
  @doc api: :low_level
  def append_request_steps(request, steps) do
    update_in(request.request_steps, &(&1 ++ steps))
  end

  @doc """
  Prepends request steps.
  """
  @doc api: :low_level
  def prepend_request_steps(request, steps) do
    update_in(request.request_steps, &(steps ++ &1))
  end

  @doc """
  Appends response steps.
  """
  @doc api: :low_level
  def append_response_steps(request, steps) do
    update_in(request.response_steps, &(&1 ++ steps))
  end

  @doc """
  Prepends response steps.
  """
  @doc api: :low_level
  def prepend_response_steps(request, steps) do
    update_in(request.response_steps, &(steps ++ &1))
  end

  @doc """
  Appends error steps.
  """
  @doc api: :low_level
  def append_error_steps(request, steps) do
    update_in(request.error_steps, &(&1 ++ steps))
  end

  @doc """
  Prepends error steps.
  """
  @doc api: :low_level
  def prepend_error_steps(request, steps) do
    update_in(request.error_steps, &(steps ++ &1))
  end

  @doc """
  Make the HTTP request using `Finch`.

  This is a request step but it is not documented as such because you don't
  need to add it to your request pipeline. It is automatically added
  by `run/1` as always the very last request step.

  This function shows you that making the actual HTTP call is just another
  request step, which means that you can write your own step that uses
  another underlying HTTP client like `:httpc`, `:hackney`, etc.
  """
  @doc api: :low_level
  def run_finch(request) do
    finch_request =
      Finch.build(request.method, request.url, request.headers, request.body)
      |> maybe_put_unix_socket(request)

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

  defp maybe_put_unix_socket(finch_request, %Req.Request{unix_socket: nil}) do
    finch_request
  end

  defp maybe_put_unix_socket(finch_request, %Req.Request{unix_socket: socket}) do
    %{finch_request | unix_socket: socket}
  end

  @doc """
  Runs a request pipeline.

  Returns `{:ok, response}` or `{:error, exception}`.
  """
  @doc api: :low_level
  def run(request) do
    request
    |> append_request_steps([&run_finch/1])
    |> run_request()
  end

  @doc """
  Runs a request pipeline and returns a response or raises an error.

  See `run/1` for more information.
  """
  @doc api: :low_level
  def run!(request) do
    case run(request) do
      {:ok, response} -> response
      {:error, exception} -> raise exception
    end
  end

  defp run_request(request) do
    steps = request.request_steps

    Enum.reduce_while(steps, request, fn step, acc ->
      case run_step(step, acc) do
        %Req.Request{} = request ->
          {:cont, request}

        {%Req.Request{halted: true}, response_or_exception} ->
          {:halt, result(response_or_exception)}

        {request, %Req.Response{} = response} ->
          {:halt, run_response(request, response)}

        {request, %{__exception__: true} = exception} ->
          {:halt, run_error(request, exception)}
      end
    end)
  end

  defp run_response(request, response) do
    steps = request.response_steps

    {_request, response_or_exception} =
      Enum.reduce_while(steps, {request, response}, fn step, {request, response} ->
        case run_step(step, {request, response}) do
          {%Req.Request{halted: true} = request, response_or_exception} ->
            {:halt, {request, response_or_exception}}

          {request, %Req.Response{} = response} ->
            {:cont, {request, response}}

          {request, %{__exception__: true} = exception} ->
            {:halt, run_error(request, exception)}
        end
      end)

    result(response_or_exception)
  end

  defp run_error(request, exception) do
    steps = request.error_steps

    {_request, response_or_exception} =
      Enum.reduce_while(steps, {request, exception}, fn step, {request, exception} ->
        case run_step(step, {request, exception}) do
          {%Req.Request{halted: true} = request, response_or_exception} ->
            {:halt, {request, response_or_exception}}

          {request, %{__exception__: true} = exception} ->
            {:cont, {request, exception}}

          {request, %Req.Response{} = response} ->
            {:halt, run_response(request, response)}
        end
      end)

    result(response_or_exception)
  end

  defp run_step({module, function, args}, arg) do
    apply(module, function, [arg | args])
  end

  defp run_step({module, args}, arg) when is_list(args) do
    run_step({module, :run, args}, arg)
  end

  defp run_step(module, arg) when is_atom(module) do
    run_step({module, :run, []}, arg)
  end

  defp run_step(func, arg) when is_function(func, 1) do
    func.(arg)
  end

  defp result(%Req.Response{} = response) do
    {:ok, response}
  end

  defp result(%{__exception__: true} = exception) do
    {:error, exception}
  end

  ## Request steps

  @doc """
  Adds default steps.

  ## Request steps

    * `encode_headers/1`

    * `default_headers/1`

    * `encode_body/1`

    * [`&put_base_url(&1, options[:base_url])`](`base_url/2`) (if `options[:base_url]` is set)

    * [`&load_netrc(&1, options[:netrc])`](`load_netrc/2`) (if `options[:netrc]` is set
      to an atom true for default path or a string for custom path)

    * [`&auth(&1, options[:auth])`](`auth/2`) (if `options[:auth]` is set)

    * [`&put_params(&1, options[:params])`](`put_params/2`) (if `options[:params]` is set)

    * [`&put_range(&1, options[:range])`](`put_range/2`) (if `options[:range]` is set)

    * [`&run_steps(&1, options[:steps])`](`run_steps/2`) (if `options[:steps]` is set)

  ## Response steps

    * [`&retry(&1, options[:retry])`](`retry/2`) (if `options[:retry]` is set to
      an atom true or a options keywords list)

    * `follow_redirects/1`

    * `decompress/1`

    * `decode_body/1`

  ## Error steps

    * [`&retry(&1, options[:retry])`](`retry/2`) (if `options[:retry]` is set and is a
      keywords list or an atom `true`)

  ## Options

    * `:base_url` - if set, adds the `put_base_url/2` step

    * `:netrc` - if set, adds the `load_netrc/2` step

    * `:auth` - if set, adds the `auth/2` step

    * `:params` - if set, adds the `put_params/2` step

    * `:range` - if set, adds the `put_range/2` step

    * `:cache` - if set to `true`, adds `put_if_modified_since/2` step

    * `:raw` if set to `true`, skips `decompress/1` and `decode_body/1` steps

    * `:retry` - if set, adds the `retry/2` step to response and error steps

    * `:steps` - if set, runs the `run_steps/2` step with the given steps

  """
  @doc api: :request
  def put_default_steps(request, options \\ []) do
    request_steps =
      [
        {Req, :encode_headers, []},
        {Req, :default_headers, []},
        {Req, :encode_body, []}
      ] ++
        maybe_steps(options[:base_url], [{Req, :put_base_url, [options[:base_url]]}]) ++
        maybe_steps(options[:netrc], [{Req, :load_netrc, [options[:netrc]]}]) ++
        maybe_steps(options[:auth], [{Req, :auth, [options[:auth]]}]) ++
        maybe_steps(options[:params], [{Req, :put_params, [options[:params]]}]) ++
        maybe_steps(options[:range], [{Req, :put_range, [options[:range]]}]) ++
        maybe_steps(options[:cache], [{Req, :put_if_modified_since, []}]) ++
        maybe_steps(options[:steps], [{Req, :run_steps, [options[:steps]]}])

    retry = options[:retry]
    retry = if retry == true, do: [], else: retry

    raw? = options[:raw] == true

    response_steps =
      maybe_steps(retry, [{Req, :retry, [retry]}]) ++
        [{Req, :follow_redirects, []}] ++
        maybe_steps(not raw?, [
          {Req, :decompress, []},
          {Req, :decode_body, []}
        ])

    error_steps = maybe_steps(retry, [{Req, :retry, [retry]}])

    request
    |> append_request_steps(request_steps)
    |> append_response_steps(response_steps)
    |> append_error_steps(error_steps)
  end

  defp maybe_steps(nil, _step), do: []
  defp maybe_steps(false, _step), do: []
  defp maybe_steps(_, steps), do: steps

  @doc """
  Sets base URL for all requests.

  ## Examples

      iex> options = [base_url: "https://httpbin.org"]
      iex> Req.get!("/status/200", options).status
      200
      iex> Req.get!("/status/201", options).status
      201
  """
  @doc api: :request
  def put_base_url(request, base_url) when is_binary(base_url) do
    # TODO: change build/3 so that the url is parsed later so that here it is not yet parsed

    unless match?(%{scheme: nil, host: nil}, request.url) do
      raise "put_base_url/2 expects the request url to only contain a path, got: #{URI.to_string(request.url)}"
    end

    # remove when we require Elixir v1.13
    url = request.url.path || ""

    url = URI.parse(base_url <> url)
    %{request | url: url}
  end

  @doc """
  Sets request authentication.

  `auth` can be one of:

    * `{username, password}` - uses Basic HTTP authentication

  ## Examples

      iex> Req.get!("https://httpbin.org/basic-auth/foo/bar", auth: {"bad", "bad"}).status
      401
      iex> Req.get!("https://httpbin.org/basic-auth/foo/bar", auth: {"foo", "bar"}).status
      200

  """
  @doc api: :request
  def auth(request, auth)

  def auth(request, {username, password}) when is_binary(username) and is_binary(password) do
    value = Base.encode64("#{username}:#{password}")
    put_new_header(request, "authorization", "Basic #{value}")
  end

  @doc """
  Sets request authentication for a matching host from a netrc file.

  ## Examples

      iex> Req.get!("https://httpbin.org/basic-auth/foo/bar").status
      401
      iex> Req.get!("https://httpbin.org/basic-auth/foo/bar", netrc: true).status
      200
      iex> Req.get!("https://httpbin.org/basic-auth/foo/bar", netrc: "/path/to/custom_netrc").status
      200

  """
  @doc api: :request
  def load_netrc(request, path)

  def load_netrc(request, path) when is_binary(path) do
    case Map.fetch(load_netrc(path), request.url.host) do
      {:ok, {username, password}} ->
        auth(request, {username, password})

      :error ->
        request
    end
  end

  def load_netrc(request, true) do
    load_netrc(request, Path.join(System.user_home!(), ".netrc"))
  end

  defp load_netrc(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> parse_netrc(nil, %{})
  end

  @user_agent "req/#{Mix.Project.config()[:version]}"

  @doc """
  Adds common request headers.

  Currently the following headers are added:

    * `"user-agent"` - `#{inspect(@user_agent)}`

    * `"accept-encoding"` - `"gzip"`

  """
  @doc api: :request
  def default_headers(request) do
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
  @doc api: :request
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
  @doc api: :request
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
  @doc api: :request
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

      iex> Req.get!("https://repo.hex.pm/builds/elixir/builds.txt", range: 0..67)
      %Req.Response{
        status: 206,
        headers: [{"content-range", "bytes 0-67/45400"}, ...],
        body: "master df65074a8143cebec810dfb91cafa43f19dcdbaf 2021-04-23T15:36:18Z"
      }

  """
  @doc api: :request
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

      iex> url = "https://hexdocs.pm/elixir/Kernel.html"
      iex> response1 = Req.get!(url, cache: true)
      iex> response2 = Req.get!(url, cache: true)
      iex> response1 == response2
      true

  """
  @doc api: :request
  def put_if_modified_since(request, options \\ []) do
    dir = options[:dir] || :filename.basedir(:user_cache, 'req')

    request
    |> do_put_if_modified_since(dir)
    |> prepend_response_steps([&handle_cache(&1, dir)])
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

  ## Examples

      iex> inspect_host = fn request -> IO.inspect(request.url.host) ; request end
      iex> Req.get!("https://httpbin.org/status/200", steps: [inspect_host]).status
      Outputs: httpbin.org
      iex> 200

  """
  @doc api: :request
  def run_steps(request, steps) when is_list(steps) do
    Enum.reduce(steps, request, &run_step/2)
  end

  ## Response steps

  @doc """
  Decompresses the response body based on the `content-encoding` header.

  ## Examples

      iex> response = Req.get!("https://httpbin.org/gzip")
      iex> response.headers
      [
        {"content-encoding", "gzip"},
        {"content-type", "application/json"},
        ...
      ]
      iex> response.body
      %{
        "gzipped" => true,
        ...
      }

  """
  @doc api: :response
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

      iex> Req.get!("https://hex.pm/api/packages/finch").body["meta"]
      %{
        "description" => "An HTTP client focused on performance.",
        "licenses" => ["MIT"],
        "links" => %{"GitHub" => "https://github.com/keathley/finch"},
        ...
      }

  """
  @doc api: :response
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

  ## Examples

      iex> Req.get!("http://api.github.com").status
      # 23:24:11.670 [debug]  Req.follow_redirects/2: Redirecting to https://api.github.com/
      200

  """
  @doc api: :response
  def follow_redirects({request, %{status: status} = response}) when status in 301..302 do
    {_, location} = List.keyfind(response.headers, "location", 0)
    Logger.debug(["Req.follow_redirects/2: Redirecting to ", location])

    request =
      if String.starts_with?(location, "/") do
        url = URI.parse(location)
        update_in(request.url, &%{&1 | path: url.path, query: url.query})
      else
        url = URI.parse(location)
        put_in(request.url, url)
      end

    {_, result} = run(request)
    {Req.Request.halt(request), result}
  end

  def follow_redirects(other) do
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
  @doc api: :error
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

      {_, result} = run(request)
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

  defp parse_netrc(["#" <> _ | rest], current_acc, acc) do
    parse_netrc(rest, current_acc, acc)
  end

  defp parse_netrc(["machine " <> machine | rest], _, acc) do
    parse_netrc(rest, {machine, nil, nil}, acc)
  end

  defp parse_netrc(["username " <> username | rest], {machine, nil, nil}, acc) do
    parse_netrc(rest, {machine, username, nil}, acc)
  end

  defp parse_netrc(["password " <> password | rest], {machine, username, nil}, acc) do
    parse_netrc(rest, nil, Map.put(acc, machine, {username, password}))
  end

  defp parse_netrc([other | rest], current_acc, acc) do
    if String.trim(other) == "" do
      parse_netrc(rest, current_acc, acc)
    else
      raise "parse error: #{inspect(other)}"
    end
  end

  defp parse_netrc([], nil, acc) do
    acc
  end
end
