defmodule Req do
  @moduledoc ~S"""
  The high-level API.

  Req is composed of:

    * `Req` - the high-level API (you're here!)

    * `Req.Request` - the low-level API and the request struct

    * `Req.Steps` - the collection of built-in steps

    * `Req.Test` - the testing conveniences

  The high-level API is what most users of Req will use most of the time.

  ## Examples

  Making a GET request with `Req.get!/1`:

      iex> Req.get!("https://api.github.com/repos/wojtekmach/req").body["description"]
      "Req is a batteries-included HTTP client for Elixir."

  Same, but by explicitly building request struct first:

      iex> req = Req.new(base_url: "https://api.github.com")
      iex> Req.get!(req, url: "/repos/wojtekmach/req").body["description"]
      "Req is a batteries-included HTTP client for Elixir."

  Return the request that was sent using `Req.run!/2`:

      iex> {req, resp} = Req.run!("https://httpbin.org/basic-auth/foo/bar", auth: {:basic, "foo:bar"})
      iex> req.headers["authorization"]
      ["Basic Zm9vOmJhcg=="]
      iex> resp.status
      200

  Making a POST request with `Req.post!/2`:

      iex> Req.post!("https://httpbin.org/post", form: [comments: "hello!"]).body["form"]
      %{"comments" => "hello!"}

  Set connection timeout:

      iex> resp = Req.get!("https://httpbin.org", connect_options: [timeout: 100])
      iex> resp.status
      200

  See [`run_finch`](`Req.Steps.run_finch/1`) for more connection related options and usage examples.

  Stream request body:

      iex> stream = Stream.duplicate("foo", 3)
      iex> Req.post!("https://httpbin.org/post", body: stream).body["data"]
      "foofoofoo"

  Stream response body using a callback:

      iex> resp =
      ...>   Req.get!("http://httpbin.org/stream/2", into: fn {:data, data}, {req, resp} ->
      ...>     IO.puts(data)
      ...>     {:cont, {req, resp}}
      ...>   end)
      # output: {"url": "http://httpbin.org/stream/2", ...}
      # output: {"url": "http://httpbin.org/stream/2", ...}
      iex> resp.status
      200
      iex> resp.body
      ""

  Stream response body into a `Collectable`:

      iex> resp = Req.get!("http://httpbin.org/stream/2", into: IO.stream())
      # output: {"url": "http://httpbin.org/stream/2", ...}
      # output: {"url": "http://httpbin.org/stream/2", ...}
      iex> resp.status
      200
      iex> resp.body
      %IO.Stream{}

  Stream response body to the current process and parse incoming messages using `Req.parse_message/2`.

      iex> resp = Req.get!("http://httpbin.org/stream/2", into: :self)
      iex> Req.parse_message(resp, receive do message -> message end)
      {:ok, [data: "{\"url\": \"http://httpbin.org/stream/2\", ..., \"id\": 0}\n"]}
      iex> Req.parse_message(resp, receive do message -> message end)
      {:ok, [data: "{\"url\": \"http://httpbin.org/stream/2\", ..., \"id\": 1}\n"]}
      iex> Req.parse_message(resp, receive do message -> message end)
      {:ok, [:done]}
      ""

  Same as above, using enumerable API:

      iex> resp = Req.get!("http://httpbin.org/stream/2", into: :self)
      iex> resp.body
      #Req.Response.Async<...>
      iex> Enum.each(resp.body, &IO.puts/1)
      # {"url": "http://httpbin.org/stream/2", ..., "id": 0}
      # {"url": "http://httpbin.org/stream/2", ..., "id": 1}
      :ok

  See `:into` option in `Req.new/1` documentation for more information on response body streaming.

  ## Headers

  The HTTP specification requires that header names should be case-insensitive.
  Req allows two ways to access the headers; using functions and by accessing
  the data directly:

      iex> Req.Response.get_header(response, "content-type")
      ["text/html"]

      iex> response.headers["content-type"]
      ["text/html"]

  While we can ensure case-insensitive handling in the former case, we can't
  in the latter. For this reason, Req made the following design choices:

    * header names are stored as downcased

    * functions like `Req.Request.get_header/2`, `Req.Request.put_header/3`,
      `Req.Response.get_header/2`, `Req.Response.put_header/3`, etc
      automatically downcase the given header name.

  > #### Note {: .tip}
  >
  > Most Elixir/Erlang HTTP clients represent headers as lists of tuples like:
  >
  > ```elixir
  > [{"content-type", "text/plain"}]`
  > ```
  >
  > For interopability with those, use
  > `Req.get_headers_list/1`.
  """

  # Response streaming to caller:
  #
  #     iex> {req, resp} = Req.async_request!("http://httpbin.org/stream/2")
  #     iex> resp.status
  #     200
  #     iex> resp.body
  #     ""
  #     iex> Req.parse_message(req, receive do message -> message end)
  #     [{:data, "{\"url\": \"http://httpbin.org/stream/2\"" <> ...}]
  #     iex> Req.parse_message(req, receive do message -> message end)
  #     [{:data, "{\"url\": \"http://httpbin.org/stream/2\"" <> ...}]
  #     iex> Req.parse_message(req, receive do message -> message end)
  #     [:done]
  #     ""

  @type url() :: URI.t() | String.t()

  @req Req.Request.new()
       |> Req.Steps.attach()

  @default_finch_options Req.Finch.pool_options(%{})

  @doc """
  Returns a new request struct with built-in steps.

  See `request/2`, `run/2`, as well as `get/2`, `post/2`, and similar functions for
  making requests.

  Also see `Req.Request` module documentation for more information on the underlying request
  struct.

  ## Options

  Basic request options:

    * `:method` - the request method, defaults to `:get`.

    * `:url` - the request URL.

    * `:headers` - the request headers as a `{key, value}` enumerable (e.g. map, keyword list).

      The header names should be downcased.

      The headers are automatically encoded using these rules:

        * atom header names are turned into strings, replacing `_` with `-`. For example,
          `:user_agent` becomes `"user-agent"`.

        * string header names are downcased.

        * `%DateTime{}` header values are encoded as "HTTP date".

      If you set `:headers` options both in `Req.new/1` and `request/2`, the header lists are merged.

      See also "Headers" section in the module documentation.

    * `:body` - the request body.

      Can be one of:

        * `iodata` - send request body eagerly

        * `enumerable` - stream `enumerable` as request body

  Additional URL options:

    * `:base_url` - if set, the request URL is prepended with this base URL (via
      [`put_base_url`](`Req.Steps.put_base_url/1`) step.)

    * `:params` - if set, appends parameters to the request query string (via
      [`put_params`](`Req.Steps.put_params/1`) step.)

    * `:path_params` - if set, uses a templated request path (via
      [`put_path_params`](`Req.Steps.put_path_params/1`) step.)

    * `:path_params_style` (*available since v0.5.1*) - how path params are expressed (via
      [`put_path_params`](`Req.Steps.put_path_params/1`) step). Can be one of:

         * `:colon` - (default) for Plug-style parameters, such as `:code` in
           `https://httpbin.org/status/:code`.

         * `:curly` - for [OpenAPI](https://swagger.io/specification/)-style parameters, such as
           `{code}` in `https://httpbin.org/status/{code}`.

  Authentication options:

    * `:auth` - sets request authentication (via [`auth`](`Req.Steps.auth/1`) step.)

      Can be one of:

        * `{:basic, userinfo}` - uses Basic HTTP authentication.

        * `{:digest, userinfo}` - uses Digest HTTP authentication.

        * `{:bearer, token}` - uses Bearer HTTP authentication.

        * `:netrc` - load credentials from the default .netrc file.

        * `{:netrc, path}` - load credentials from `path`.

        * `string` - sets to this value.

        * `&fun/0` - a function that returns one of the above (such as a `{:bearer, token}`).

        * `{mod, fun, args}` - an MFArgs tuple that returns one of the above (such as a `{:bearer, token}`).

  Request body encoding options ([`encode_body`](`Req.Steps.encode_body/1`)):

    * `:form` - if set, encodes the request body as `application/x-www-form-urlencoded`

    * `:form_multipart` - if set, encodes the request body as `multipart/form-data`.

    * `:json` - if set, encodes the request body as JSON

  Other request body options:

    * `:compress_body` - if set to `true`, compresses the request body using gzip (via [`compress_body`](`Req.Steps.compress_body/1`) step.)
      Defaults to `false`.

  AWS Signature Version 4 options ([`put_aws_sigv4`](`Req.Steps.put_aws_sigv4/1`) step):

    * `:aws_sigv4` - if set, the AWS options to sign request:

        * `:access_key_id` - the AWS access key id.

        * `:secret_access_key` - the AWS secret access key.

        * `:service` - the AWS service.

        * `:region` - if set, AWS region. Defaults to `"us-east-1"`.

        * `:datetime` - the request datetime, defaults to `DateTime.utc_now(:second)`.

  Response body options:

    * `:compressed` - if set to `true`, asks the server to return compressed response.
      (via [`compressed`](`Req.Steps.compressed/1`) step.) Defaults to `true`.

    * `:raw` - if set to `true`, disables automatic body decompression
      ([`decompress_body`](`Req.Steps.decompress_body/1`) step) and decoding
      ([`decode_body`](`Req.Steps.decode_body/1`) step.) Defaults to `false`.

    * `:decode_body` - if set to `false`, disables automatic response body decoding.
      Defaults to `true`.

    * `:decode_json` - options to pass to `Jason.decode!/2`, defaults to `[]`.

    * `:into` - where to send the response body. It can be one of:

        * `nil` - (default) read the whole response body and store it in the `response.body`
          field.

        * `fun` - stream response body using a function. The first argument is a `{:data, data}`
          tuple containing the chunk of the response body. The second argument is a
          `{request, response}` tuple. To continue streaming chunks, return `{:cont, {req, resp}}`.
          To cancel, return `{:halt, {req, resp}}`. For example:

              into: fn {:data, data}, {req, resp} ->
                IO.puts(data)
                {:cont, {req, resp}}
              end

        * `collectable` - stream response body into a `t:Collectable.t/0`. For example:

               into: File.stream!("path")

          Note that the collectable is only used, if the response status is 200. In other cases,
          the body is accumulated and processed as usual.

        * `:self` - stream response body into the current process mailbox.

          Received messages should be parsed with `Req.parse_message/2`.

          `response.body` is set to opaque data structure `Req.Response.Async` which implements
          `Enumerable` that receives and automatically parses messages. See module documentation
          for example usage.

          If the request is sent using HTTP/1, an extra process is spawned to consume messages
          from the underlying socket. On both HTTP/1 and HTTP/2 the messages are sent to the
          current process as soon as they arrive, as a firehose. If you wish to maximize request
          rate or have more control over how messages are streamed, use `into: fun` or
          `into: collectable` instead.

  Response redirect options ([`redirect`](`Req.Steps.redirect/1`) step):

    * `:redirect` - if set to `false`, disables automatic response redirects. Defaults to `true`.

    * `:redirect_trusted` - by default, authorization credentials are only sent on redirects
      with the same host, scheme and port. If `:redirect_trusted` is set to `true`, credentials
      will be sent to any host.

    * `:max_redirects` - the maximum number of redirects, defaults to `10`.

  Other response options:

    * `:http_errors` - how to handle HTTP 4xx/5xx error responses (via
      [`handle_http_errors`](`Req.Steps.handle_http_errors/1`) step).
      Can be one of the following:

      * `:return` (default) - return the response

      * `:raise` - raise an error

  Retry options ([`retry`](`Req.Steps.retry/1`) step):

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
      the default delay follows a simple exponential backoff: 1s, 2s, 4s, 8s, ...

      `:retry_delay` can be set to a function that receives the retry count (starting at 0)
      and returns the delay, the number of milliseconds to sleep before making another attempt.

    * `:retry_log_level` - the log level to emit retry logs at. Can also be set to `false` to disable
      logging these messages. Defaults to `:warning`.

    * `:max_retries` - maximum number of retry attempts, defaults to `3` (for a total of `4`
      requests to the server, including the initial one.)

  Caching options ([`cache`](`Req.Steps.cache/1`) step):

    * `:cache` - if `true`, performs HTTP caching. Defaults to `false`.

    * `:cache_dir` - the directory to store the cache, defaults to `<user_cache_dir>/req`
      (see: `:filename.basedir/3`)

  Request adapters:

    * `:adapter` - adapter to use to make the actual HTTP request. See `:adapter` field description
      in the `Req.Request` module documentation for more information.

      The default is [`run_finch`](`Req.Steps.run_finch/1`).

    * `:plug` - if set, calls the given plug instead of making an HTTP request over the network (via [`run_plug`](`Req.Steps.run_plug/1`) step).

      The plug can be one of:

        * A _function_ plug: a `fun(conn)` or `fun(conn, options)` function that takes a
          `Plug.Conn` and returns a `Plug.Conn`.

        * A _module_ plug: a `module` name or a `{module, options}` tuple.

  Finch options ([`run_finch`](`Req.Steps.run_finch/1`) step), see `Finch.start_link/1` for options:

    * `:finch` - the Finch pool to use. Defaults to pool automatically started by `Req`.

    * `:connect_options` - dynamically starts (or re-uses already started) Finch pool with
      the given connection options (see `Mint.HTTP.connect/4` for options):

        * `:timeout` - socket connect timeout in milliseconds, defaults to `30_000`.

        * `:protocols` - the HTTP protocols to use, defaults to
          `#{inspect(Keyword.fetch!(@default_finch_options, :protocols))}`.

        * `:hostname` - Mint explicit hostname.

        * `:transport_opts` - Mint transport options.

        * `:proxy_headers` - Mint proxy headers.

        * `:proxy` - Mint HTTP/1 proxy settings, a `{schema, address, port, options}` tuple.

        * `:client_settings` - Mint HTTP/2 client settings.

    * `:inet6` - if set to true, uses IPv6. Defaults to `false`.

    * `:pool_timeout` - pool checkout timeout in milliseconds, defaults to `5000`.

    * `:receive_timeout` - socket receive timeout in milliseconds, defaults to `15_000`.

    * `:unix_socket` - if set, connect through the given UNIX domain socket.

    * `:pool_max_idle_time` - the maximum number of milliseconds that a pool can be
      idle before being terminated, used only by HTTP1 pools. Default to `:infinity`.

    * `:finch_private` - a map or keyword list of private metadata to add to the Finch request. May be useful
      for adding custom data when handling telemetry with `Finch.Telemetry`.

    * `:finch_request` - a function that executes the Finch request, defaults to using `Finch.request/3`.

  ## Examples

      iex> req = Req.new(url: "https://elixir-lang.org")
      iex> req.method
      :get
      iex> URI.to_string(req.url)
      "https://elixir-lang.org"

  Fake adapter:

      iex> fake = fn request ->
      ...>   {request, Req.Response.new(status: 200, body: "it works!")}
      ...> end
      iex>
      iex> req = Req.new(adapter: fake)
      iex> Req.get!(req).body
      "it works!"

  """
  @spec new(options :: keyword()) :: Req.Request.t()
  def new(options \\ []) do
    options = Keyword.merge(default_options(), options)
    {plugins, options} = Keyword.pop(options, :plugins, [])

    @req
    |> run_plugins(plugins)
    |> merge(options)
  end

  defp new(%Req.Request{} = request, options) when is_list(options) do
    Req.merge(request, options)
  end

  defp new(options1, options2) when is_list(options1) and is_list(options2) do
    new(options1 ++ options2)
  end

  defp new(url, options) when (is_binary(url) or is_struct(url, URI)) and is_list(options) do
    new([url: url] ++ options)
  end

  defp new(request, options) when is_list(options) do
    raise ArgumentError,
          "expected 1st argument to be a request, got: #{inspect(request)}"
  end

  defp new(_request, options) do
    raise ArgumentError,
          "expected 2nd argument to be an options keywords list, got: #{inspect(options)}"
  end

  @doc false
  @deprecated "Use Req.merge/2 instead"
  def update(request, options) do
    Req.merge(request, options)
  end

  @doc """
  Updates a request struct.

  See `new/1` for a list of available options. Also see `Req.Request` module documentation
  for more information on the underlying request struct.

  ## Examples

      iex> req = Req.new(base_url: "https://httpbin.org")
      iex> req = Req.merge(req, auth: {:basic, "alice:secret"})
      iex> req.options[:base_url]
      "https://httpbin.org"
      iex> req.options[:auth]
      {:basic, "alice:secret"}

  Passing `:headers` will automatically encode and merge them:

      iex> req = Req.new(headers: %{point_x: 1})
      iex> req = Req.merge(req, headers: %{point_y: 2})
      iex> req.headers
      %{"point-x" => ["1"], "point-y" => ["2"]}

  The same header names are overwritten however:

      iex> req = Req.new(headers: %{authorization: "bearer foo"})
      iex> req = Req.merge(req, headers: %{authorization: "bearer bar"})
      iex> req.headers
      %{"authorization" => ["bearer bar"]}

  Similarly to headers, `:params` are merged too:

      req = Req.new(url: "https://httpbin.org/anything", params: [a: 1, b: 1])
      req = Req.merge(req, params: [a: 2])
      Req.get!(req).body["args"]
      #=> %{"a" => "2", "b" => "1"}
  """
  @spec merge(Req.Request.t(), options :: keyword()) :: Req.Request.t()
  def merge(%Req.Request{} = request, options) when is_list(options) do
    # TODO: Remove on Req 1.0
    if Keyword.has_key?(options, :redact_auth) do
      IO.warn("Setting :redact_auth is deprecated and has no effect")
    end

    request_option_names = [:method, :url, :headers, :body, :adapter, :into]

    {request_options, options} = Keyword.split(options, request_option_names)

    if options[:output] && unquote(!System.get_env("REQ_NOWARN_OUTPUT")) do
      IO.warn("setting `output: path` is deprecated in favour of `into: File.stream!(path)`")
    end

    registered =
      MapSet.union(
        request.registered_options,
        MapSet.new(request_option_names)
      )

    Req.Request.validate_options(options, registered)

    request =
      Enum.reduce(request_options, request, fn
        {:url, url}, acc ->
          put_in(acc.url, URI.parse(url))

        {:headers, new_headers}, acc ->
          update_in(acc.headers, &Req.Fields.merge(&1, new_headers))

        {name, value}, acc ->
          %{acc | name => value}
      end)

    update_in(
      request.options,
      &Map.merge(&1, Map.new(options), fn
        :params, old, new ->
          Keyword.merge(old, new)

        _, _, new ->
          new
      end)
    )
  end

  @doc """
  Makes a GET request and returns a response or an error.

  `request` can be one of:

    * an url (`String` or `URI`);

    * a `Keyword` options;

    * a `Req.Request` struct

  See `new/1` for a list of available options.

  ## Examples

  With URL:

      iex> {:ok, resp} = Req.get("https://api.github.com/repos/wojtekmach/req")
      iex> resp.body["description"]
      "Req is a batteries-included HTTP client for Elixir."

  With options:

      iex> {:ok, resp} = Req.get(url: "https://api.github.com/repos/wojtekmach/req")
      iex> resp.status
      200

  With request struct:

      iex> req = Req.new(base_url: "https://api.github.com")
      iex> {:ok, resp} = Req.get(req, url: "/repos/elixir-lang/elixir")
      iex> resp.status
      200

  """
  @doc type: :request
  @spec get(url() | keyword() | Req.Request.t(), options :: keyword()) ::
          {:ok, Req.Response.t()} | {:error, Exception.t()}
  def get(request, options \\ []) do
    request(%{new(request, options) | method: :get})
  end

  @doc """
  Makes a GET request and returns a response or raises an error.

  `request` can be one of:

    * an url (`String` or `URI`);

    * a `Keyword` options;

    * a `Req.Request` struct

  See `new/1` for a list of available options.

  ## Examples

  With URL:

      iex> Req.get!("https://api.github.com/repos/wojtekmach/req").body["description"]
      "Req is a batteries-included HTTP client for Elixir."

  With options:

      iex> Req.get!(url: "https://api.github.com/repos/wojtekmach/req").status
      200

  With request struct:

      iex> req = Req.new(base_url: "https://api.github.com")
      iex> Req.get!(req, url: "/repos/elixir-lang/elixir").status
      200

  """
  @doc type: :request
  @spec get!(url() | keyword() | Req.Request.t(), options :: keyword()) :: Req.Response.t()
  def get!(request, options \\ []) do
    request!(%{new(request, options) | method: :get})
  end

  @doc """
  Makes a HEAD request and returns a response or an error.

  `request` can be one of:

    * an url (`String` or `URI`);

    * a `Keyword` options;

    * a `Req.Request` struct

  See `new/1` for a list of available options.

  ## Examples

  With URL:

      iex> {:ok, resp} = Req.head("https://httpbin.org/status/201")
      iex> resp.status
      201

  With options:

      iex> {:ok, resp} = Req.head(url: "https://httpbin.org/status/201")
      iex> resp.status
      201

  With request struct:

      iex> req = Req.new(base_url: "https://httpbin.org")
      iex> {:ok, resp} = Req.head(req, url: "/status/201")
      iex> resp.status
      201

  """
  @doc type: :request
  @spec head(url() | keyword() | Req.Request.t(), options :: keyword()) ::
          {:ok, Req.Response.t()} | {:error, Exception.t()}
  def head(request, options \\ []) do
    request(%{new(request, options) | method: :head})
  end

  @doc """
  Makes a HEAD request and returns a response or raises an error.

  `request` can be one of:

    * an url (`String` or `URI`);

    * a `Keyword` options;

    * a `Req.Request` struct

  See `new/1` for a list of available options.

  ## Examples

  With URL:

      iex> Req.head!("https://httpbin.org/status/201").status
      201

  With options:

      iex> Req.head!(url: "https://httpbin.org/status/201").status
      201

  With request struct:

      iex> req = Req.new(base_url: "https://httpbin.org")
      iex> Req.head!(req, url: "/status/201").status
      201
  """
  @doc type: :request
  @spec head!(url() | keyword() | Req.Request.t(), options :: keyword()) :: Req.Response.t()
  def head!(request, options \\ []) do
    request!(%{new(request, options) | method: :head})
  end

  @doc """
  Makes a POST request and returns a response or an error.

  `request` can be one of:

    * an url (`String` or `URI`);

    * a `Keyword` options;

    * a `Req.Request` struct

  See `new/1` for a list of available options.

  ## Examples

  With URL:

      iex> {:ok, resp} = Req.post("https://httpbin.org/anything", body: "hello!")
      iex> resp.body["data"]
      "hello!"

      iex> {:ok, resp} = Req.post("https://httpbin.org/anything", form: [x: 1])
      iex> resp.body["form"]
      %{"x" => "1"}

      iex> {:ok, resp} = Req.post("https://httpbin.org/anything", json: %{x: 2})
      iex> resp.body["json"]
      %{"x" => 2}

  With options:

      iex> {:ok, resp} = Req.post(url: "https://httpbin.org/anything", body: "hello!")
      iex> resp.body["data"]
      "hello!"

  With request struct:

      iex> req = Req.new(url: "https://httpbin.org/anything")
      iex> {:ok, resp} = Req.post(req, body: "hello!")
      iex> resp.body["data"]
      "hello!"
  """
  @doc type: :request
  @spec post(url() | keyword() | Req.Request.t(), options :: keyword()) ::
          {:ok, Req.Response.t()} | {:error, Exception.t()}
  def post(request, options \\ []) do
    request(%{new(request, options) | method: :post})
  end

  @doc """
  Makes a POST request and returns a response or raises an error.

  `request` can be one of:

    * an url (`String` or `URI`);

    * a `Keyword` options;

    * a `Req.Request` struct

  See `new/1` for a list of available options.

  ## Examples

  With URL:

      iex> Req.post!("https://httpbin.org/anything", body: "hello!").body["data"]
      "hello!"

      iex> Req.post!("https://httpbin.org/anything", form: [x: 1]).body["form"]
      %{"x" => "1"}

      iex> Req.post!("https://httpbin.org/anything", json: %{x: 2}).body["json"]
      %{"x" => 2}

  With options:

      iex> Req.post!(url: "https://httpbin.org/anything", body: "hello!").body["data"]
      "hello!"

  With request struct:

      iex> req = Req.new(url: "https://httpbin.org/anything")
      iex> Req.post!(req, body: "hello!").body["data"]
      "hello!"
  """
  @doc type: :request
  @spec post!(url() | keyword() | Req.Request.t(), options :: keyword()) :: Req.Response.t()
  def post!(request, options \\ []) do
    request!(%{new(request, options) | method: :post})
  end

  @doc """
  Makes a PUT request and returns a response or an error.

  `request` can be one of:

    * an url (`String` or `URI`);

    * a `Keyword` options;

    * a `Req.Request` struct

  See `new/1` for a list of available options.

  ## Examples

  With URL:

      iex> {:ok, resp} = Req.put("https://httpbin.org/anything", body: "hello!")
      iex> resp.body["data"]
      "hello!"

  With options:

      iex> {:ok, resp} = Req.put(url: "https://httpbin.org/anything", body: "hello!")
      iex> resp.body["data"]
      "hello!"

  With request struct:

      iex> req = Req.new(url: "https://httpbin.org/anything")
      iex> {:ok, resp} = Req.put(req, body: "hello!")
      iex> resp.body["data"]
      "hello!"
  """
  @doc type: :request
  @spec put(url() | keyword() | Req.Request.t(), options :: keyword()) ::
          {:ok, Req.Response.t()} | {:error, Exception.t()}
  def put(request, options \\ []) do
    request(%{new(request, options) | method: :put})
  end

  @doc """
  Makes a PUT request and returns a response or raises an error.

  `request` can be one of:

    * an url (`String` or `URI`);

    * a `Keyword` options;

    * a `Req.Request` struct

  See `new/1` for a list of available options.

  ## Examples

  With URL:

      iex> Req.put!("https://httpbin.org/anything", body: "hello!").body["data"]
      "hello!"

  With options:

      iex> Req.put!(url: "https://httpbin.org/anything", body: "hello!").body["data"]
      "hello!"

  With request struct:

      iex> req = Req.new(url: "https://httpbin.org/anything")
      iex> Req.put!(req, body: "hello!").body["data"]
      "hello!"
  """
  @doc type: :request
  @spec put!(url() | keyword() | Req.Request.t(), options :: keyword()) :: Req.Response.t()
  def put!(request, options \\ []) do
    request!(%{new(request, options) | method: :put})
  end

  @doc """
  Makes a PATCH request and returns a response or an error.

  `request` can be one of:

    * an url (`String` or `URI`);

    * a `Keyword` options;

    * a `Req.Request` struct

  See `new/1` for a list of available options.

  ## Examples

  With URL:

      iex> {:ok, resp} = Req.patch("https://httpbin.org/anything", body: "hello!")
      iex> resp.body["data"]
      "hello!"

  With options:

      iex> {:ok, resp} = Req.patch(url: "https://httpbin.org/anything", body: "hello!")
      iex> resp.body["data"]
      "hello!"

  With request struct:

      iex> req = Req.new(url: "https://httpbin.org/anything")
      iex> {:ok, resp} = Req.patch(req, body: "hello!")
      iex> resp.body["data"]
      "hello!"
  """
  @doc type: :request
  @spec patch(url() | keyword() | Req.Request.t(), options :: keyword()) ::
          {:ok, Req.Response.t()} | {:error, Exception.t()}
  def patch(request, options \\ []) do
    request(%{new(request, options) | method: :patch})
  end

  @doc """
  Makes a PATCH request and returns a response or raises an error.

  `request` can be one of:

    * an url (`String` or `URI`);

    * a `Keyword` options;

    * a `Req.Request` struct

  See `new/1` for a list of available options.

  ## Examples

  With URL:

      iex> Req.patch!("https://httpbin.org/anything", body: "hello!").body["data"]
      "hello!"

  With options:

      iex> Req.patch!(url: "https://httpbin.org/anything", body: "hello!").body["data"]
      "hello!"

  With request struct:

      iex> req = Req.new(url: "https://httpbin.org/anything")
      iex> Req.patch!(req, body: "hello!").body["data"]
      "hello!"
  """
  @doc type: :request
  @spec patch!(url() | keyword() | Req.Request.t(), options :: keyword()) :: Req.Response.t()
  def patch!(request, options \\ []) do
    request!(%{new(request, options) | method: :patch})
  end

  @doc """
  Makes a DELETE request and returns a response or an error.

  `request` can be one of:

    * an url (`String` or `URI`);

    * a `Keyword` options;

    * a `Req.Request` struct

  See `new/1` for a list of available options.

  ## Examples

  With URL:

      iex> {:ok, resp} = Req.delete("https://httpbin.org/anything")
      iex> resp.body["method"]
      "DELETE"

  With options:

      iex> {:ok, resp} = Req.delete(url: "https://httpbin.org/anything")
      iex> resp.body["method"]
      "DELETE"

  With request struct:

      iex> req = Req.new(url: "https://httpbin.org/anything")
      iex> {:ok, resp} = Req.delete(req)
      iex> resp.body["method"]
      "DELETE"
  """
  @doc type: :request
  @spec delete(url() | keyword() | Req.Request.t(), options :: keyword()) ::
          {:ok, Req.Response.t()} | {:error, Exception.t()}
  def delete(request, options \\ []) do
    request(%{new(request, options) | method: :delete})
  end

  @doc """
  Makes a DELETE request and returns a response or raises an error.

  `request` can be one of:

    * an url (`String` or `URI`);

    * a `Keyword` options;

    * a `Req.Request` struct

  See `new/1` for a list of available options.

  ## Examples

  With URL:

      iex> Req.delete!("https://httpbin.org/anything").body["method"]
      "DELETE"

  With options:

      iex> Req.delete!(url: "https://httpbin.org/anything").body["method"]
      "DELETE"

  With request struct:

      iex> req = Req.new(url: "https://httpbin.org/anything")
      iex> Req.delete!(req).body["method"]
      "DELETE"
  """
  @doc type: :request
  @spec delete!(url() | keyword() | Req.Request.t(), options :: keyword()) :: Req.Response.t()
  def delete!(request, options \\ []) do
    request!(%{new(request, options) | method: :delete})
  end

  @doc """
  Makes an HTTP request and returns a response or an error.

  `request` can be one of:

    * a `Keyword` options;
    * a `Req.Request` struct

  See `new/1` for a list of available options.

  Also see `run/2` for a similar function that returns the request and the response or error.

  ## Examples

  With options keywords list:

      iex> {:ok, response} = Req.request(url: "https://api.github.com/repos/wojtekmach/req")
      iex> response.status
      200
      iex> response.body["description"]
      "Req is a batteries-included HTTP client for Elixir."

  With request struct:

      iex> req = Req.new(url: "https://api.github.com/repos/elixir-lang/elixir")
      iex> {:ok, response} = Req.request(req)
      iex> response.status
      200
  """
  @doc type: :request
  @spec request(request :: Req.Request.t() | keyword(), options :: keyword()) ::
          {:ok, Req.Response.t()} | {:error, Exception.t()}
  def request(request, options \\ []) do
    Req.Request.run(new(request, options))
  end

  @doc """
  Makes an HTTP request and returns a response or raises an error.

  See `new/1` for a list of available options.

  Also see `run!/2` for a similar function that returns the request and the response or error.

  ## Examples

  With options keywords list:

      iex> Req.request!(url: "https://api.github.com/repos/elixir-lang/elixir").status
      200

  With request struct:

      iex> req = Req.new(url: "https://api.github.com/repos/elixir-lang/elixir")
      iex> Req.request!(req).status
      200
  """
  @doc type: :request
  @spec request!(request :: Req.Request.t() | keyword(), options :: keyword()) :: Req.Response.t()
  def request!(request, options \\ []) do
    case request(request, options) do
      {:ok, response} -> response
      {:error, exception} -> raise exception
    end
  end

  @doc """
  Makes an HTTP request and returns the request and response or error.

  `request` can be one of:

    * an url (`String` or `URI`);

    * a `Keyword` options;

    * a `Req.Request` struct

  See `new/1` for a list of available options.

  Also see `request/2` for a similar function that returns the response or error
  (without the request).

  ## Examples

  With options keywords list:

      iex> {req, resp} = Req.run(url: "https://api.github.com/repos/elixir-lang/elixir")
      iex> req.url.host
      "api.github.com"
      iex> resp.status
      200

  With request struct and options:

      iex> req = Req.new(base_url: "https://api.github.com")
      iex> {req, resp} = Req.run(req, url: "/repos/elixir-lang/elixir")
      iex> req.url.host
      "api.github.com"
      iex> resp.status
      200

  Returns an error:

      iex> {_req, exception} = Req.run("http://localhost:9999", retry: false)
      iex> exception
      %Req.TransportError{reason: :econnrefused}

  """
  @doc type: :request
  @spec run(request :: url() | keyword() | Req.Request.t(), options :: keyword()) ::
          {Req.Request.t(), Req.Response.t() | Exception.t()}
  def run(request, options \\ [])

  def run(request, options) when is_list(options) do
    Req.Request.run_request(new(request, options))
  end

  def run(_request, options) do
    raise ArgumentError,
          "expected 2nd argument to be an options keywords list, got: #{inspect(options)}"
  end

  @doc """
  Makes an HTTP request and returns the request and response or raises on errors.

  `request` can be one of:

    * an url (`String` or `URI`);

    * a `Keyword` options;

    * a `Req.Request` struct

  See `new/1` for a list of available options.

  Also see `request!/2` for a similar function that returns the response (without the request).

  ## Examples

  With options keywords list:

      iex> {req, resp} = Req.run!(url: "https://api.github.com/repos/elixir-lang/elixir")
      iex> req.url.host
      "api.github.com"
      iex> resp.status
      200

  With request struct and options:

      iex> req = Req.new(base_url: "https://api.github.com")
      iex> {req, resp} = Req.run!(req, url: "/repos/elixir-lang/elixir")
      iex> req.url.host
      "api.github.com"
      iex> resp.status
      200

  Raises an error:

      iex> Req.run!("http://localhost:9999", retry: false)
      ** (Req.TransportError) connection refused
  """
  @doc type: :request
  @spec run!(request :: url() | keyword() | Req.Request.t(), options :: keyword()) ::
          {Req.Request.t(), Req.Response.t()}
  def run!(request, options \\ []) do
    case run(request, options) do
      {req, %Req.Response{} = resp} ->
        {req, resp}

      {_req, exception} ->
        raise exception
    end
  end

  @doc false
  @deprecated "use Req.request(into: self()) instead"
  def async_request(request, options \\ []) do
    Req.Request.run_request(%{new(request, options) | into: :legacy_self})
  end

  @deprecated "use Req.request!(into: self()) instead"
  @doc false
  def async_request!(request, options \\ []) do
    case async_request(request, options) do
      {request, %Req.Response{} = response} ->
        {request, response}

      {_request, exception} ->
        raise exception
    end
  end

  @doc """
  Parses asynchronous response body message.

  A request with option `:into` set to `:self` returns response with asynchronous body.
  In that case, Req sends chunks to the calling process as messages. You'd typically
  get them using `receive/1` or [`handle_info/2`](`c:GenServer.handle_info/2`) in a GenServer.
  These messages should be parsed using this function. The possible return values are:

    * `{:ok, chunks}` - where a chunk can be `{:data, binary}`, `{:trailers, trailers}`, or
      `:done`.

    * `{:error, reason}` - an error occured

    * `:unknown` - the message was not meant for this response.

  See also `Req.Response.Async`.

  ## Examples

      iex> resp = Req.get!("http://httpbin.org/stream/2", into: :self)
      iex> Req.parse_message(resp, receive do message -> message end)
      {:ok, [data: "{\"url\": \"http://httpbin.org/stream/2\", ..., \"id\": 0}\\n"]}
      iex> Req.parse_message(resp, receive do message -> message end)
      {:ok, [data: "{\"url\": \"http://httpbin.org/stream/2\", ..., \"id\": 1}\\n"]}
      iex> Req.parse_message(resp, receive do message -> message end)
      {:ok, [:done]}
      iex> Req.parse_message(resp, :other)
      :unknown
  """
  @doc type: :async
  def parse_message(response, message)

  def parse_message(%Req.Response{body: %Req.Response.Async{stream_fun: fun, ref: ref}}, message) do
    fun.(ref, message)
  end

  def parse_message(%Req.Request{} = request, message) do
    IO.warn(
      "passing %Req.Request{} to parse_message/2 is deprecated. Pass %Req.Response{} instead"
    )

    request.async.stream_fun.(request.async.ref, message)
  end

  @doc """
  Cancels an asynchronous response.

  An asynchronous response is a result of request with `into: :self`.
  See also `Req.Response.Async`.

  ## Examples

      iex> resp = Req.get!("http://httpbin.org/stream/2", into: :self)
      iex> Req.cancel_async_response(resp)
      :ok
  """
  @doc type: :async
  def cancel_async_response(%Req.Response{body: %Req.Response.Async{cancel_fun: fun, ref: ref}}) do
    fun.(ref)
  end

  @deprecated "use Req.cancel_async_response(resp)) instead"
  @doc false
  def cancel_async_request(%Req.Request{} = request) do
    request.async.cancel_fun.(request.async.ref)
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

  @doc """
  Returns request/response headers as list.

  ## Examples

      iex> req = Req.Request.new(headers: %{"accept" => ["application/json"]})
      iex> Req.get_headers_list(req)
      [{"accept", "application/json"}]

      iex> resp = Req.Response.new(headers: %{"content-type" => ["application/json"]})
      iex> Req.get_headers_list(resp)
      [{"content-type", "application/json"}]
  """
  @doc since: "0.5.10"
  @spec get_headers_list(Req.Request.t() | Req.Response.t()) :: [{binary(), binary()}]
  def get_headers_list(%struct{headers: headers}) when struct in [Req.Request, Req.Response] do
    Req.Fields.get_list(headers)
  end

  # Plugins support is experimental and undocumented.
  defp run_plugins(request, [plugin | rest]) when is_atom(plugin) do
    run_plugins(plugin.attach(request), rest)
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
