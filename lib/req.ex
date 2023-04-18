defmodule Req do
  @moduledoc """
  The high-level API.

  Req is composed of three main pieces:

    * `Req` - the high-level API (you're here!)

    * `Req.Request` - the low-level API and the request struct

    * `Req.Steps` - the collection of built-in steps

  The high-level API is what most users of Req will use most of the time.

  ## Examples

  Making a GET request with `Req.get!/1`:

      iex> Req.get!("https://api.github.com/repos/elixir-lang/elixir").body["description"]
      "Elixir is a dynamic, functional language designed for building scalable and maintainable applications"

  Same, but by explicitly building request struct first:

      iex> req = Req.new(base_url: "https://api.github.com")
      iex> Req.get!(req, url: "/repos/elixir-lang/elixir").body["description"]
      "Elixir is a dynamic, functional language designed for building scalable and maintainable applications"

  Making a POST request with `Req.post!/2`:

      iex> Req.post!("https://httpbin.org/post", form: [comments: "hello!"]).body["form"]
      %{"comments" => "hello!"}
  """

  @type url() :: URI.t() | String.t()

  @doc """
  Returns a new request struct with built-in steps.

  See `request/1` for a list of available options. See `Req.Request` module documentation
  for more information on the underlying request struct.

  ## Examples

      iex> req = Req.new(url: "https://elixir-lang.org")
      iex> req.method
      :get
      iex> URI.to_string(req.url)
      "https://elixir-lang.org"

  """
  @spec new(options :: keyword()) :: Req.Request.t()
  def new(options \\ []) do
    options = Keyword.merge(default_options(), options)
    {plugins, options} = Keyword.pop(options, :plugins, [])

    %Req.Request{
      registered_options:
        MapSet.new([
          :user_agent,
          :compressed,
          :range,
          :http_errors,
          :base_url,
          :params,
          :path_params,
          :auth,
          :form,
          :json,
          :compress_body,
          :compressed,
          :raw,
          :decode_body,
          :extract,
          :output,
          :follow_redirects,
          :location_trusted,
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
          :connect_options,
          :receive_timeout,
          :pool_timeout,
          :unix_socket
        ])
    }
    |> update(options)
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
      compress_body: &Req.Steps.compress_body/1
    )
    |> Req.Request.prepend_response_steps(
      retry: &Req.Steps.retry/1,
      follow_redirects: &Req.Steps.follow_redirects/1,
      decompress_body: &Req.Steps.decompress_body/1,
      decode_body: &Req.Steps.decode_body/1,
      handle_http_errors: &Req.Steps.handle_http_errors/1,
      output: &Req.Steps.output/1
    )
    |> Req.Request.prepend_error_steps(retry: &Req.Steps.retry/1)
    |> run_plugins(plugins)
  end

  @doc """
  Updates a request struct.

  See `request/1` for a list of available options. See `Req.Request` module documentation
  for more information on the underlying request struct.

  ## Examples

      iex> req = Req.new(base_url: "https://httpbin.org")
      iex> req = Req.update(req, auth: {"alice", "secret"})
      iex> req.options
      %{auth: {"alice", "secret"}, base_url: "https://httpbin.org"}

  Passing `:headers` will automatically encode and merge them:

      iex> req = Req.new(headers: [point_x: 1])
      iex> req = Req.update(req, headers: [point_y: 2])
      iex> req.headers
      [{"point-x", "1"}, {"point-y", "2"}]

  """
  @spec update(Req.Request.t(), options :: keyword()) :: Req.Request.t()
  def update(%Req.Request{} = request, options) when is_list(options) do
    request_option_names = [:method, :url, :headers, :body, :adapter]

    {request_options, options} = Keyword.split(options, request_option_names)

    registered =
      MapSet.union(
        request.registered_options,
        MapSet.new(request_option_names)
      )

    Req.Request.validate_options(options, registered)

    request_options =
      if request_options[:headers] do
        update_in(request_options[:headers], &encode_headers/1)
      else
        request_options
      end

    request =
      Map.merge(request, Map.new(request_options), fn
        :url, _, url ->
          URI.parse(url)

        :headers, old, new ->
          old ++ new

        _, _, value ->
          value
      end)

    request = update_in(request.options, &Map.merge(&1, Map.new(options)))

    if request.options[:output] do
      update_in(request.options, &Map.put(&1, :decode_body, false))
    else
      request
    end
  end

  @doc """
  Makes a GET request.

  See `request/1` for a list of supported options.

  ## Examples

  With URL:

      iex> Req.get!("https://api.github.com/repos/elixir-lang/elixir").body["description"]
      "Elixir is a dynamic, functional language designed for building scalable and maintainable applications"

  With request struct:

      iex> req = Req.new(base_url: "https://api.github.com")
      iex> Req.get!(req, url: "/repos/elixir-lang/elixir").status
      200

  """
  @spec get!(url() | Req.Request.t(), options :: keyword()) :: Req.Response.t()
  def get!(url_or_request, options \\ []) do
    case get(url_or_request, options) do
      {:ok, response} -> response
      {:error, exception} -> raise exception
    end
  end

  @doc """
  Makes a GET request.

  See `request/1` for a list of supported options.

  ## Examples

  With URL:

      iex> {:ok, res} = Req.get("https://api.github.com/repos/elixir-lang/elixir")
      iex> res.body["description"]
      "Elixir is a dynamic, functional language designed for building scalable and maintainable applications"

  With request struct:

      iex> req = Req.new(base_url: "https://api.github.com")
      iex> {:ok, res} = Req.get(req, url: "/repos/elixir-lang/elixir")
      iex> res.status
      200

  """
  @spec get(url() | Req.Request.t(), options :: keyword()) ::
          {:ok, Req.Response.t()} | {:error, Exception.t()}
  def get(url_or_request, options \\ [])

  def get(%Req.Request{} = request, options) do
    request(%{request | method: :get}, options)
  end

  def get(url, options) do
    request([method: :get, url: URI.parse(url)] ++ options)
  end

  @doc """
  Makes a HEAD request.

  See `request/1` for a list of supported options.

  ## Examples

  With URL:

      iex> Req.head!("https://httpbin.org/status/201").status
      201

  With request struct:

      iex> req = Req.new(base_url: "https://httpbin.org")
      iex> Req.head!(req, url: "/status/201").status
      201

  """
  @spec head!(url() | Req.Request.t(), options :: keyword()) :: Req.Response.t()
  def head!(url_or_request, options \\ []) do
    case head(url_or_request, options) do
      {:ok, response} -> response
      {:error, exception} -> raise exception
    end
  end

  @doc """
  Makes a HEAD request.

  See `request/1` for a list of supported options.

  ## Examples

  With URL:

      iex> {:ok, res} = Req.head("https://httpbin.org/status/201")
      iex> res.status
      201

  With request struct:

      iex> req = Req.new(base_url: "https://httpbin.org")
      iex> {:ok, res} = Req.head(req, url: "/status/201")
      iex> res.status
      201

  """
  @spec head(url() | Req.Request.t(), options :: keyword()) :: Req.Response.t()
  def head(url_or_request, options \\ [])

  def head(%Req.Request{} = request, options) do
    request(%{request | method: :head}, options)
  end

  def head(url, options) do
    request([method: :head, url: URI.parse(url)] ++ options)
  end

  @doc """
  Makes a POST request.

  See `request/1` for a list of supported options.

  ## Examples

  With URL:

      iex> Req.post!("https://httpbin.org/anything", body: "hello!").body["data"]
      "hello!"

      iex> Req.post!("https://httpbin.org/anything", form: [x: 1]).body["form"]
      %{"x" => "1"}

      iex> Req.post!("https://httpbin.org/anything", json: %{x: 2}).body["json"]
      %{"x" => 2}

  With request struct:

      iex> req = Req.new(url: "https://httpbin.org/anything")
      iex> Req.post!(req, body: "hello!").body["data"]
      "hello!"
  """
  @spec post!(url() | Req.Request.t(), options :: keyword()) :: Req.Response.t()
  def post!(url_or_request, options \\ []) do
    if Keyword.keyword?(options) do
      case post(url_or_request, options) do
        {:ok, response} -> response
        {:error, exception} -> raise exception
      end
    else
      case options do
        {:form, data} ->
          IO.warn(
            "Req.post!(url, {:form, data}) is deprecated in favour of " <>
              "Req.post!(url, form: data)"
          )

          request!(method: :post, url: URI.parse(url_or_request), form: data)

        {:json, data} ->
          IO.warn(
            "Req.post!(url, {:json, data}) is deprecated in favour of " <>
              "Req.post!(url, json: data)"
          )

          request!(method: :post, url: URI.parse(url_or_request), json: data)

        data ->
          IO.warn("Req.post!(url, body) is deprecated in favour of Req.post!(url, body: body)")
          request!(method: :post, url: URI.parse(url_or_request), body: data)
      end
    end
  end

  @doc false
  def post!(url, body, options) do
    case body do
      {:form, data} ->
        IO.warn(
          "Req.post!(url, {:form, data}, options) is deprecated in favour of " <>
            "Req.post!(url, [form: data] ++ options)"
        )

        request!([method: :post, url: URI.parse(url), form: data] ++ options)

      {:json, data} ->
        IO.warn(
          "Req.post!(url, {:json, data}) is deprecated in favour of " <>
            "Req.post!(url, [json: data] ++ options)"
        )

        request!([method: :post, url: URI.parse(url), json: data] ++ options)

      data ->
        IO.warn(
          "Req.post!(url, body) is deprecated in favour of " <>
            "Req.post!(url, [body: body] ++ options)"
        )

        request!([method: :post, url: URI.parse(url), body: data] ++ options)
    end
  end

  @doc """
  Makes a POST request.

  See `request/1` for a list of supported options.

  ## Examples

  With URL:

      iex> {:ok, res} = Req.post("https://httpbin.org/anything", body: "hello!")
      iex> res.body["data"]
      "hello!"

      iex> {:ok, res} = Req.post("https://httpbin.org/anything", form: [x: 1])
      iex> res.body["form"]
      %{"x" => "1"}

      iex> {:ok, res} = Req.post("https://httpbin.org/anything", json: %{x: 2})
      iex> res.body["json"]
      %{"x" => 2}

  With request struct:

      iex> req = Req.new(url: "https://httpbin.org/anything")
      iex> {:ok, res} = Req.post(req, body: "hello!")
      iex> res.body["data"]
      "hello!"
  """
  @spec post(url() | Req.Request.t(), options :: keyword()) ::
          {:ok, Req.Response.t()} | {:error, Exception.t()}
  def post(url_or_request, options \\ [])

  def post(%Req.Request{} = request, options) do
    request(%{request | method: :post}, options)
  end

  def post(url, options) do
    request([method: :post, url: URI.parse(url)] ++ options)
  end

  @doc """
  Makes a PUT request.

  See `request/1` for a list of supported options.

  ## Examples

  With URL:

      iex> Req.put!("https://httpbin.org/anything", body: "hello!").body["data"]
      "hello!"

  With request struct:

      iex> req = Req.new(url: "https://httpbin.org/anything")
      iex> Req.put!(req, body: "hello!").body["data"]
      "hello!"
  """
  @spec put!(url() | Req.Request.t(), options :: keyword()) :: Req.Response.t()
  def put!(url_or_request, options \\ []) do
    case put(url_or_request, options) do
      {:ok, response} -> response
      {:error, exception} -> raise exception
    end
  end

  @doc false
  def put!(%URI{} = url, {type, _} = body, options) when type in [:form, :json] do
    IO.warn(
      "Req.put!(url, {:#{type}, #{type}}, options) is deprecated in favour of " <>
        "Req.put!(url, [#{type}: #{type}] ++ options)"
    )

    request!([method: :put, url: url, body: body] ++ options)
  end

  @doc """
  Makes a PUT request.

  See `request/1` for a list of supported options.

  ## Examples

  With URL:

      iex> {:ok, res} = Req.put("https://httpbin.org/anything", body: "hello!")
      iex> res.body["data"]
      "hello!"

  With request struct:

      iex> req = Req.new(url: "https://httpbin.org/anything")
      iex> {:ok, res} = Req.put(req, body: "hello!")
      iex> res.body["data"]
      "hello!"
  """
  @spec put(url() | Req.Request.t(), options :: keyword()) ::
          {:ok, Req.Response.t()} | {:error, Exception.t()}
  def put(url_or_request, options \\ [])

  def put(%Req.Request{} = request, options) do
    request(%{request | method: :put}, options)
  end

  def put(url, options) do
    if Keyword.keyword?(options) do
      request([method: :put, url: URI.parse(url)] ++ options)
    else
      IO.warn("Req.put!(url, body) is deprecated in favour of Req.put!(url, body: body)")
      request(url: URI.parse(url), body: options)
    end
  end

  @doc """
  Makes a PATCH request.

  See `request/1` for a list of supported options.

  ## Examples

  With URL:

      iex> Req.patch!("https://httpbin.org/anything", body: "hello!").body["data"]
      "hello!"

  With request struct:

      iex> req = Req.new(url: "https://httpbin.org/anything")
      iex> Req.patch!(req, body: "hello!").body["data"]
      "hello!"
  """
  @spec patch!(url() | Req.Request.t(), options :: keyword()) :: Req.Response.t()
  def patch!(url_or_request, options \\ []) do
    case patch(url_or_request, options) do
      {:ok, response} -> response
      {:error, exception} -> raise exception
    end
  end

  @doc """
  Makes a PATCH request.

  See `request/1` for a list of supported options.

  ## Examples

  With URL:

      iex> {:ok, res} = Req.patch("https://httpbin.org/anything", body: "hello!")
      iex> res.body["data"]
      "hello!"

  With request struct:

      iex> req = Req.new(url: "https://httpbin.org/anything")
      iex> {:ok, res} = Req.patch(req, body: "hello!")
      iex> res.body["data"]
      "hello!"
  """
  @spec patch(url() | Req.Request.t(), options :: keyword()) ::
          {:ok, Req.Response.t()} | {:error, Exception.t()}
  def patch(url_or_request, options \\ [])

  def patch(%Req.Request{} = request, options) do
    request(%{request | method: :patch}, options)
  end

  def patch(url, options) do
    request([method: :patch, url: url] ++ options)
  end

  @doc """
  Makes a DELETE request.

  See `request/1` for a list of supported options.

  ## Examples

  With URL:

      iex> Req.delete!("https://httpbin.org/anything").body["method"]
      "DELETE"

  With request struct:

      iex> req = Req.new(url: "https://httpbin.org/anything")
      iex> Req.delete!(req).body["method"]
      "DELETE"
  """
  @spec delete!(url() | Req.Request.t(), options :: keyword()) :: Req.Response.t()
  def delete!(url_or_request, options \\ []) do
    case delete(url_or_request, options) do
      {:ok, response} -> response
      {:error, exception} -> raise exception
    end
  end

  @doc """
  Makes a DELETE request.

  See `request/1` for a list of supported options.

  ## Examples

  With URL:

      iex> {:ok, res} = Req.delete("https://httpbin.org/anything")
      iex> res.body["method"]
      "DELETE"

  With request struct:

      iex> req = Req.new(url: "https://httpbin.org/anything")
      iex> {:ok, res} = Req.delete(req)
      iex> res.body["method"]
      "DELETE"
  """
  @spec delete(url() | Req.Request.t(), options :: keyword()) ::
          {:ok, Req.Response.t()} | {:error, Exception.t()}
  def delete(url_or_request, options \\ [])

  def delete(%Req.Request{} = request, options) do
    request(%{request | method: :delete}, options)
  end

  def delete(url, options) do
    request([method: :delete, url: url] ++ options)
  end

  @doc """
  Makes an HTTP request.

  `request/1` and `request/2` functions give three ways of making requests:

    1. With a list of options, for example:

       ```
       iex> Req.request(url: url)
       ```

    2. With a request struct, for example:

       ```
       iex> Req.new(url: url) |> Req.request()
       ```

    3. With a request struct and more options, for example:

       ```
       iex> Req.new(base_url: base_url) |> Req.request(url: url)
       ```

  This function as well as all the other ones in this module accept the same set of options described below.

  ## Options

  Basic request options:

    * `:method` - the request method, defaults to `:get`.

    * `:url` - the request URL.

    * `:headers` - the request headers.

      The headers are automatically encoded using these rules:

        * atom header names are turned into strings, replacing `_` with `-`. For example,
          `:user_agent` becomes `"user-agent"`

        * string header names are left as is. Because header keys are case-insensitive
          in both HTTP/1.1 and HTTP/2, it is recommended for header keys to be in
          lowercase, to avoid sending duplicate keys in a request.

        * `DateTime` header values are encoded as "HTTP date". Otherwise,
          the header value is encoded with `String.Chars.to_string/1`.

      If you set `:headers` options both in `Req.new/1` and `request/2`, the header lists are merged.

    * `:body` - the request body.

  Additional URL options:

    * `:base_url` - if set, the request URL is prepended with this base URL (via
      [`put_base_url`](`Req.Steps.put_base_url/1`) step).

    * `:params` - if set, appends parameters to the request query string (via
      [`put_params`](`Req.Steps.put_params/1`) step).

    * `:path_params` - if set, uses a templated request path (via
      [`put_path_params`](`Req.Steps.put_path_params/1`) step).

  Authentication options:

    * `:auth` - sets request authentication (via [`auth`](`Req.Steps.auth/1`) step).
      Can be one of:

        * `string` - sets to this value;

        * `{username, password}` - uses Basic HTTP authentication;

        * `{:bearer, token}` - uses Bearer HTTP authentication;

        * `:netrc` - load credentials from the default .netrc file;

        * `{:netrc, path}` - load credentials from `path`

  Request body options:

    * `:form` - if set, encodes the request body as form data ([`encode_body`](`Req.Steps.encode_body/1`) step).

    * `:json` - if set, encodes the request body as JSON ([`encode_body`](`Req.Steps.encode_body/1`) step).

    * `:compress_body` - if set to `true`, compresses the request body using gzip (via [`compress_body`](`Req.Steps.compress_body/1`) step).
      Defaults to `false`.

  Response body options:

    * `:compressed` - if set to `true`, asks the server to return compressed response.
      (via [`compressed`](`Req.Steps.compressed/1`) step). Defaults to `true`.

    * `:raw` - if set to `true`, disables automatic body decompression
      ([`decompress_body`](`Req.Steps.decompress_body/1`) step) and decoding
      ([`decode_body`](`Req.Steps.decode_body/1`) step). Defaults to `false`.

    * `:decode_body` - if set to `false`, disables automatic response body decoding.
      Defaults to `true`.

    * `:extract` - if set to a path, extracts archives (tar, zip, etc) into the
      given directory and sets the response body to the list of extracted filenames.

    * `:output` - if set, writes the response body to a file (via
      [`output`](`Req.Steps.output/1`) step). Can be set to a string path or an atom
      `:remote_name` which would use the remote name as the filename in the current working
      directory. Once the file is written, the response body is replaced with `""`.

      Setting `:output` also sets the `decode_body: false` option to prevent decoding the
      response before writing it to the file.

  Response redirect options ([`follow_redirects`](`Req.Steps.follow_redirects/1`) step):

    * `:follow_redirects` - if set to `false`, disables automatic response redirects. Defaults to `true`.

    * `:location_trusted` - by default, authorization credentials are only sent
      on redirects with the same host, scheme and port. If `:location_trusted` is set to `true`, credentials
      will be sent to any host.

    * `:max_redirects` - the maximum number of redirects, defaults to `10`.

  Retry options ([`retry`](`Req.Steps.retry/1`) step):

    * `:retry`: can be set to: `:safe` (default) to only retry GET/HEAD requests on HTTP 408/5xx
      responses or exceptions, `false` to never retry, and `fun` - a 1-arity function that accepts
      either a `Req.Response` or an exception struct and returns boolean whether to retry

    * `:retry_delay` - a function that receives the retry count (starting at 0) and returns the delay, the
      number of milliseconds to sleep before making another attempt.
      Defaults to a simple exponential backoff: 1s, 2s, 4s, 8s, ...

    * `:max_retries` - maximum number of retry attempts, defaults to `3` (for a total of `4`
      requests to the server, including the initial one.)

  Caching options ([`cache`](`Req.Steps.cache/1`) step):

    * `:cache` - if `true`, performs HTTP caching. Defaults to `false`.

    * `:cache_dir` - the directory to store the cache, defaults to `<user_cache_dir>/req`
      (see: `:filename.basedir/3`)

  Request adapters:

    * `:adapter` - adapter to use to make the actual HTTP request. See `:adapter` field description
      in the `Req.Request` module documentation for more information. Defaults to calling [`run_finch`](`Req.Steps.run_finch/1`).

    * `:plug` - if set, calls the given Plug instead of making an HTTP request over the network (via [`put_plug`](`Req.Steps.put_plug/1`) step).

  Finch options ([`run_finch`](`Req.Steps.run_finch/1`) step)

    * `:finch` - the Finch pool to use. Defaults to pool automatically started by `Req`.

    * `:connect_options` - dynamically starts (or re-uses already started) Finch pool with
      the given connection options:

        * `:timeout` - socket connect timeout in milliseconds, defaults to `30_000`.

        * `:protocol` - the HTTP protocol to use, defaults to `:http1`.

        * `:hostname` - Mint explicit hostname

        * `:transport_opts` - Mint transport options

        * `:proxy_headers` - Mint proxy headers

        * `:proxy` - Mint HTTP/1 proxy settings, a `{schema, address, port, options}` tuple.

        * `:client_settings` - Mint HTTP/2 client settings

    * `:pool_timeout` - pool checkout timeout in milliseconds, defaults to `5000`.

    * `:receive_timeout` - socket receive timeout in milliseconds, defaults to `15_000`.

    * `:unix_socket` - if set, connect through the given UNIX domain socket
    
    * `:finch_request` - a function to modify the built Finch request before execution. This function takes a 
       Finch request and returns a Finch request. If not provided, the finch request will not be modified

  ## Examples

  With options keywords list:

      iex> {:ok, response} = Req.request(url: "https://api.github.com/repos/elixir-lang/elixir")
      iex> response.status
      200
      iex> response.body["description"]
      "Elixir is a dynamic, functional language designed for building scalable and maintainable applications"

  With request struct:

      iex> req = Req.new(url: "https://api.github.com/repos/elixir-lang/elixir")
      iex> {:ok, response} = Req.request(req)
      iex> response.status
      200

  With request struct and options:

      iex> req = Req.new(base_url: "https://api.github.com")
      iex> {:ok, response} = Req.request(req, url: "/repos/elixir-lang/elixir")
      iex> response.status
      200

  With mock adapter:

      iex> adapter = fn request ->
      ...>   response = %Req.Response{status: 200, body: "it works!"}
      ...>   {request, response}
      ...> end
      iex>
      iex> {:ok, response} = Req.request(adapter: adapter, url: "http://example")
      iex> response.body
      "it works!"
  """
  @spec request(Req.Request.t() | keyword()) :: {:ok, Req.Response.t()} | {:error, Exception.t()}
  def request(request_or_options)

  def request(%Req.Request{} = request) do
    request(request, [])
  end

  def request(options) do
    request(Req.new(options), [])
  end

  @doc """
  Makes an HTTP request.

  See `request/1` for more information.
  """
  @spec request(Req.Request.t(), options :: keyword()) ::
          {:ok, Req.Response.t()} | {:error, Exception.t()}
  def request(request, options) when is_list(options) do
    {plugins, options} = Keyword.pop(options, :plugins, [])

    request
    |> Req.update(options)
    |> run_plugins(plugins)
    |> Req.Request.run()
  end

  @doc false
  def request(method, url, options) do
    IO.warn(
      "Req.request(method, url, options) is deprecated in favour of " <>
        "Req.request!([method: method, url: url] ++ options)"
    )

    request([method: method, url: URI.parse(url)] ++ options)
  end

  @doc """
  Makes an HTTP request and returns a response or raises an error.

  See `request/1` for more information.

  ## Examples

      iex> Req.request!(url: "https://api.github.com/repos/elixir-lang/elixir").status
      200
  """
  @spec request!(Req.Request.t() | keyword()) :: Req.Response.t()
  def request!(request_or_options) do
    case request(request_or_options) do
      {:ok, response} -> response
      {:error, exception} -> raise exception
    end
  end

  @doc """
  Makes an HTTP request and returns a response or raises an error.

  See `request/1` for more information.

  ## Examples

      iex> req = Req.new(base_url: "https://api.github.com")
      iex> Req.request!(req, url: "/repos/elixir-lang/elixir").status
      200
  """
  @spec request!(Req.Request.t(), options :: keyword()) :: Req.Response.t()
  def request!(request, options) do
    case request(request, options) do
      {:ok, response} -> response
      {:error, exception} -> raise exception
    end
  end

  @doc """
  Returns default options.

  See `default_options/1` for more information.
  """
  @spec default_options() :: keyword()
  def default_options() do
    Application.get_env(:req, :default_options, [])
  end

  @doc """
  Sets default options for `Req.new/1`.

  Avoid setting default options in libraries as they are global.

  ## Examples

      iex> Req.default_options(base_url: "https://httpbin.org")
      iex> Req.get!("/statuses/201").status
      201
      iex> Req.new() |> Req.get!(url: "/statuses/201").status
      201
  """
  @spec default_options(keyword()) :: :ok
  def default_options(options) do
    Application.put_env(:req, :default_options, options)
  end

  defp encode_headers(headers) do
    for {name, value} <- headers do
      name =
        case name do
          atom when is_atom(atom) ->
            atom |> Atom.to_string() |> String.replace("_", "-")

          binary when is_binary(binary) ->
            binary
        end

      value =
        case value do
          %DateTime{} = datetime ->
            datetime |> DateTime.shift_zone!("Etc/UTC") |> Req.Steps.format_http_datetime()

          %NaiveDateTime{} = datetime ->
            IO.warn("setting header to %NaiveDateTime{} is deprecated, use %DateTime{} instead")
            Req.Steps.format_http_datetime(datetime)

          _ ->
            String.Chars.to_string(value)
        end

      {name, value}
    end
  end

  # Plugins support is experimental, undocumented, and likely won't make the new release.
  defp run_plugins(request, [plugin | rest]) when is_atom(plugin) do
    if Code.ensure_loaded?(plugin) and function_exported?(plugin, :attach, 1) do
      run_plugins(plugin.attach(request), rest)
    else
      run_plugins(plugin.run(request), rest)
    end
  end

  defp run_plugins(request, [plugin | rest]) when is_function(plugin, 1) do
    run_plugins(plugin.(request), rest)
  end

  defp run_plugins(request, []) do
    request
  end

  @doc false
  @deprecated "Manually build Req.Request struct instead"
  def build(method, url, options \\ []) do
    %Req.Request{
      method: method,
      url: URI.parse(url),
      headers: Keyword.get(options, :headers, []),
      body: Keyword.get(options, :body, "")
    }
  end
end
