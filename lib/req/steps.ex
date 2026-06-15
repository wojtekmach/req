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
      :decoders,
      :decode_json,
      :expect,
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
      # TODO: Deprecate :finch_request option.
      :finch_request,
      :finch_private,
      :connect_options,
      :inet6,
      :request_timeout,
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
      put_aws_sigv4: &Req.Steps.put_aws_sigv4/1,
      decode_body: &Req.Steps.decode_body/1,
      decompress_body: &Req.Steps.decompress_body/1,
      expect: &Req.Steps.expect/1,
      redirect: &Req.Steps.redirect/1,
      retry: &Req.Steps.retry/1
    )
    |> Req.Request.prepend_response_steps(
      handle_http_errors: &Req.Steps.handle_http_errors/1,
      http_digest: &Req.Steps.handle_http_digest/1,
      verify_checksum: &Req.Steps.verify_checksum/1,
      output: &Req.Steps.output/1
    )
    # Status-based retries happen in the stream (`retry/1` as a request-step wrapper). Transport
    # and HTTP errors surface before any stream exists, so they can only be retried on the error
    # path.
    |> Req.Request.prepend_error_steps(retry: &Req.Steps.retry/1)
  end

  ## Request steps

  @default_decoders [:json, :json_api, :ndjson]

  # event-stream (SSE) is decoded by default when streaming; ndjson and others are opt-in.
  @default_stream_decoders @default_decoders ++ [:event_stream]

  # Formats whose decoders run incrementally on streamed chunks.
  @stream_decoders %{"event-stream" => Req.EventStream, "ndjson" => Req.NDJSON}

  @doc """
  Decodes response body based on the detected format.

  By default, JSON and newline-delimited JSON (ndjson) responses are decoded; when streaming via
  `Req.stream/4`, server-sent event streams (`text/event-stream`) are decoded by default too.
  Other formats are opt-in via the `:decoders` option.

  ## Built-in decoders

  | Format                  | Decoder                                                        | Streaming |
  | ----------------------- | -------------------------------------------------------------- | --------- |
  | `:json`, `:json_api`    | `Jason.decode(term)` (**enabled by default**)                  |           |
  | `:event_stream`         | `Req.EventStream` (**enabled by default when streaming**)      | ✔         |
  | `:ndjson`               | `Req.NDJSON` (**enabled by default**)                         | ✔         |
  | `:zip`                  | `Req.ZIP.decode(term)`                                         |           |
  | `:tar`, `:tgz`          | `Req.Tar.decode(term)`                                         |           |
  | `:gz`                   | `:zlib.gunzip(term)`                                           |           |
  | `:zst`                  | `:zstd.decompress(term)` (requires Erlang/OTP 28+)             |           |
  | `:csv`                  | `NimbleCSV.RFC4180.parse_string(term)` (requires [nimble_csv]) | ✔         |

  The format is determined by the response `content-type` header. See `MIME` for registering
  content-type/format mapping.

  If response body is not a binary, in other words it has been transformed by another step, it
  is left as is.

  > #### Decompression Bombs {: .warning}
  >
  > The archive and compression decoders (`:zip`, `:tar`, `:tgz`, `:gz`, and `:zst`) decompress
  > the whole response body into memory with no size limit, so a small response can expand to
  > many gigabytes. For this reason they are **not** enabled by default; only opt into them via
  > the `:decoders` option for endpoints you trust.

  ## Request Options

    * `:decoders` - the list of decoders to use. Defaults to `[:json, :json_api, :ndjson]`.

      Each element is either:

        * a format (atom) handled by a [built-in decoder](#decode_body/1-built-in-decoders),
          e.g. `:json` or `:zip`;

        * a `{format, codec}` tuple, where `format` is an atom and `codec` is one of:

            * another format (atom), to reuse a built-in decoder, e.g. `decoders: [jsonl: :ndjson]`;

            * a module exporting `decode/1` that returns `{:ok, term}` or `{:error, exception}`;

            * a 1-arity function that returns `{:ok, term}` or `{:error, exception}`.

      Setting `:decoders` replaces the default, so include `:json` if you still want JSON decoded:

          # handles json, zip, and tar:
          Req.new(decoders: [:json, :zip, :tar])

      Set `:decoders` to `false` to disable all decoding, including JSON.

    * `:raw` - if set to `true`, disables response body decoding. Defaults to `false`.

      Note: setting `raw: true` also disables response body decompression in the
      `decompress_body/1` step.

  ## Examples

  Decode JSON:

      iex> response = Req.get!("https://httpbin.org/json")
      ...> response.body["slideshow"]["title"]
      "Sample Slide Show"

  Decode a ZIP archive (opt-in):

      iex> response = Req.get!("https://example.com/archive.zip", decoders: [:zip])
      ...> response.body["file.txt"]
      "contents"

  Custom decoder:

      iex> Mix.install([:req, :ical])
      iex> url = "https://www.gov.uk/bank-holidays/england-and-wales.ics"
      iex> events = Req.get!(url, decoders: [ics: &{:ok, ICal.from_ics(&1)}]).body.events
      iex> for event <- events, event.dtstart.year == 2026 do
      ...>   IO.puts("\#{event.dtstart} \#{event.summary}")
      ...> end
      # 2026-01-01 New Year’s Day
      # 2026-04-03 Good Friday
      # 2026-04-06 Easter Monday
      # 2026-05-04 Early May bank holiday
      # 2026-05-25 Spring bank holiday
      # 2026-08-31 Summer bank holiday
      # 2026-12-25 Christmas Day
      # 2026-12-28 Boxing Day

  [nimble_csv]: https://hex.pm/packages/nimble_csv
  """
  @doc step: :request
  def decode_body(%Req.Request{stream: nil} = request) do
    warn_deprecated_decode_body(request)
    request
  end

  def decode_body(%Req.Request{stream: fun} = request) when is_function(fun, 3) do
    warn_deprecated_decode_body(request)
    %{request | stream: &decode_stream_chunk(&1, &2, &3, fun)}
  end

  # Decodes a fully-buffered response body. Called by `decode_stream_chunk/4` at `:eof` for
  # non-streaming requests, once the buffer has materialized `response.body`.
  defp decode_buffered_body({request, %{body: body} = response})
       when request.async != nil or
              body == "" or
              not is_binary(body) do
    {request, response}
  end

  defp decode_buffered_body({request, response}) do
    # TODO: remove on Req 1.0
    output? = request.options[:output] not in [nil, false]

    if request.options[:raw] == true or
         request.options[:decode_body] == false or
         request.options[:decoders] == false or
         output? or
         Req.Response.get_header(response, "content-encoding") != [] do
      {request, response}
    else
      decoders = build_decoders(request, request.options[:decoders] || @default_decoders)

      case decoders[format(request, response)] do
        nil ->
          {request, response}

        codec ->
          run_decoder(request, response, codec)
      end
    end
  end

  defp warn_deprecated_decode_body(request) do
    case Req.Request.fetch_option(request, :decode_body) do
      {:ok, _value} ->
        IO.warn(
          "the `:decode_body` option is deprecated, use `decoders: false` to disable decoding",
          []
        )

      :error ->
        :ok
    end
  end

  # Buffered (non-streaming) requests collect the raw body and decode it whole at `:eof`. This
  # handles every format — `json`, `ndjson`, `event-stream` — via `decode_buffered_body/1`.
  defp decode_stream_chunk(:eof, %{request: %{private: %{req_buffer: true}}} = resp, acc, fun) do
    with {:ok, resp, acc} <- fun.(:eof, resp, acc) do
      case decode_buffered_body({resp.request, resp}) do
        {_request, %Req.Response{} = resp} ->
          {:ok, resp, acc}

        {_request, exception} ->
          {:error, resp, exception, acc}
      end
    end
  end

  defp decode_stream_chunk(data, %{request: %{private: %{req_buffer: true}}} = resp, acc, fun) do
    fun.(data, resp, acc)
  end

  defp decode_stream_chunk(data_or_eof, resp, acc, fun) do
    decoder = streaming_decoder(resp.request, resp)

    case {decoder, data_or_eof} do
      {nil, :eof} ->
        fun.(:eof, resp, acc)

      {nil, data} ->
        fun.(data, resp, acc)

      {decoder, :eof} ->
        case decoder.stream_finish(decoder_state(resp, decoder)) do
          {:ok, events, _state} ->
            reduce_events(events, resp, acc, fun)

          {:error, exception, _state} ->
            {:error, resp, exception, acc}
        end

      {decoder, data} ->
        case decoder.stream_chunk(data, decoder_state(resp, decoder)) do
          {:ok, events, state} ->
            resp = put_in(resp.request.private[:req_stream_decoder], state)
            reduce_events(events, resp, acc, fun)

          {:error, exception, _state} ->
            {:error, resp, exception, acc}
        end
    end
  end

  # Resolves the streaming decoder module for the response, but only when its format is one of
  # the configured `:decoders`. SSE is decoded by default; ndjson and others are opt-in.
  defp streaming_decoder(request, resp) do
    format = format(request, resp)

    if MapSet.member?(enabled_formats(request, @default_stream_decoders), format) do
      Map.get(@stream_decoders, format)
    end
  end

  defp decoder_state(resp, decoder) do
    case resp.request.private do
      %{req_stream_decoder: state} -> state
      _ -> decoder.stream_start(resp)
    end
  end

  defp reduce_events(events, resp, acc, fun) do
    Enum.reduce_while(events, {:ok, resp, acc}, fn event, {:ok, resp, acc} ->
      case fun.(event, resp, acc) do
        {:ok, resp, acc} -> {:cont, {:ok, resp, acc}}
        {:error, resp, exception, acc} -> {:halt, {:error, resp, exception, acc}}
      end
    end)
  end

  @doc """
  Decompresses the response body based on the `content-encoding` header.

  This step only runs when the `:compressed` option is set to `true` (see the `compressed/1`
  step); otherwise the body is left as is. This guards against decompression bombs, where a
  small compressed response expands into a much larger body in memory.

  This step handles both buffered and streamed response bodies:

    * On regular requests, it runs as a response step and decompresses `response.body`.

    * When the response body is being streamed via `Req.stream/3`, it runs as a request step
      that wraps `request.stream` so that raw body chunks are decompressed before being passed
      to `decode_body/1` and the streaming function. Decompression state is kept in
      `response.request.private[:req_stream_decompress]` between chunks. The `content-encoding`
      response encodings are decompressed in reverse order of how they were applied, but only
      if all of them were advertised in the request `accept-encoding` header; responses with
      other encodings are passed through unchanged.

  Supported formats:

  | Format        | Decoder                                         |
  | ------------- | ----------------------------------------------- |
  | gzip, x-gzip  | `:zlib.gunzip/1`                                |
  | br            | `:brotli.decode/1` (if [brotli] is installed)   |
  | zstd          | `:zstd.decompress/1` (requires Erlang/OTP 28+)  |
  | _other_       | Returns data as is                              |

  This step updates the following headers to reflect the changes:

    * `content-encoding` is removed
    * `content-length` is removed

  ## Options

    * `:compressed` - if set to `true`, decompresses the response body. Defaults to `false`.
      See also the `compressed/1` step.

    * `:raw` - if set to `true`, disables response body decompression. Defaults to `false`.

      Note: setting `raw: true` also disables response body decoding in the `decode_body/1`
      step.

  ## Examples

      iex> response = Req.get!("https://httpbin.org/gzip", compressed: true)
      iex> response.body["gzipped"]
      true

  If the [brotli] package is installed, Brotli is also supported:

      Mix.install([
        :req,
        {:brotli, "~> 0.3.0"}
      ])

      response = Req.get!("https://httpbin.org/brotli", compressed: true)
      Req.Response.get_header(response, "content-encoding")
      #=> ["br"]
      response.body["brotli"]
      #=> true

  [brotli]: https://hex.pm/packages/brotli
  """
  @doc step: :request
  def decompress_body(%Req.Request{stream: nil} = request) do
    request
  end

  def decompress_body(%Req.Request{stream: fun} = request) when is_function(fun, 3) do
    if Req.Request.get_option(request, :compressed, false) == true and
         request.options[:raw] != true do
      %{request | stream: &decompress_stream_chunk(&1, &2, &3, fun)}
    else
      request
    end
  end

  defp decompress_stream_chunk(:eof, resp, acc, fun) do
    case resp.request.private[:req_stream_decompress] do
      # The decoder is only started once non-empty data arrives, so an empty body (e.g. a HEAD
      # or 204 response) flows straight through without a spurious truncated-stream error.
      nil ->
        fun.(:eof, resp, acc)

      state ->
        case Req.DecompressStream.stream_finish(state) do
          {:ok, events, _state} ->
            with {:ok, resp, acc} <- reduce_events(events, resp, acc, fun) do
              fun.(:eof, resp, acc)
            end

          {:error, exception, _state} ->
            {:error, resp, exception, acc}
        end
    end
  end

  defp decompress_stream_chunk("", resp, acc, fun) do
    fun.("", resp, acc)
  end

  defp decompress_stream_chunk(data, resp, acc, fun) do
    state = decompress_state(resp)
    resp = strip_content_encoding(resp, state)

    case Req.DecompressStream.stream_chunk(data, state) do
      {:ok, events, state} ->
        resp = put_in(resp.request.private[:req_stream_decompress], state)
        reduce_events(events, resp, acc, fun)

      {:error, exception, _state} ->
        {:error, resp, exception, acc}
    end
  end

  # The body was decompressed, so the `content-encoding`/`content-length` headers no longer
  # describe it.
  defp strip_content_encoding(resp, codecs) when is_list(codecs) do
    resp
    |> Req.Response.delete_header("content-encoding")
    |> Req.Response.delete_header("content-length")
  end

  # Passthrough: the body is unchanged, but drop the no-op "identity" encoding (keeping any
  # unsupported ones, which still describe the body).
  defp strip_content_encoding(resp, :identity) do
    remaining =
      resp
      |> Req.Response.get_header("content-encoding")
      |> Enum.flat_map(&String.split(&1, ",", trim: true))
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(String.downcase(&1, :ascii) == "identity"))

    if remaining == [] do
      resp
      |> Req.Response.delete_header("content-encoding")
      |> Req.Response.delete_header("content-length")
    else
      Req.Response.put_header(resp, "content-encoding", Enum.join(remaining, ", "))
    end
  end

  defp decompress_state(resp) do
    case resp.request.private do
      %{req_stream_decompress: state} -> state
      _ -> Req.DecompressStream.stream_start(resp)
    end
  end

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

  This step also enables the [`decompress_body`](`Req.Steps.decompress_body/1`) step, which
  decompresses the response body. Both steps are off by default; set `compressed: true` to opt in.

  Supported formats:

    * `gzip`

    * `br` (if [brotli] is installed)

    * `zstd` (requires Erlang/OTP 28+)

  > #### Only enable compression for trusted servers {: .info}
  >
  > The `decompress_body/1` step decompresses the whole response body into memory with no size
  > limit, so a small response can expand into many gigabytes. A malicious or compromised server
  > can exploit this to exhaust memory and crash the client (a decompression bomb / denial of
  > service). For this reason compression is off by default; only set `compressed: true` for
  > endpoints you trust.

  ## Request Options

    * `:compressed` - if set to `true`, sets the `accept-encoding` header with compression
      algorithms that Req supports and decompresses the response body. Defaults to `false`.

      This option has no effect when streaming the response body (`into: fun | collectable`).

  ## Examples

  By default, Req does not ask for a compressed response. Pass `compressed: true` to request one
  and have Req decompress the body, so we get back the decompressed content:

      iex> response = Req.get!("https://elixir-lang.org", compressed: true)
      iex> response.body |> binary_part(0, 15)
      "<!DOCTYPE html>"

  To inspect the raw compressed bytes the server sent, additionally pass `raw: true`, which
  disables decompression. Notice the body now starts with `<<31, 139>>`, the "magic bytes"
  for gzip:

      iex> response = Req.get!("https://elixir-lang.org", compressed: true, raw: true)
      iex> Req.Response.get_header(response, "content-encoding")
      ["gzip"]
      iex> response.body |> binary_part(0, 2)
      <<31, 139>>

  Zstandard is supported out of the box on Erlang/OTP 28+ (via the built-in `:zstd` module).
  Brotli is supported if the optional [brotli] package is installed:

      Mix.install([
        :req,
        {:brotli, "~> 0.3.0"}
      ])

      response = Req.get!("https://httpbin.org/anything", compressed: true)
      response.body["headers"]["Accept-Encoding"]
      #=> "zstd, br, gzip"

  [brotli]: https://hex.pm/packages/brotli
  """
  @doc step: :request
  def compressed(%Req.Request{into: nil} = request) do
    case Req.Request.get_option(request, :compressed, false) do
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

  defp zstd_available? do
    System.otp_release() >= "28"
  end

  defp supported_accept_encoding do
    value = "gzip"
    value = if brotli_loaded?(), do: "br, " <> value, else: value
    if zstd_available?(), do: "zstd, " <> value, else: value
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

    * `:json` - if set, encodes the request body as JSON (using `JSON.encode_to_iodata!/1`), sets
      the `accept` header to `application/json`, and the `content-type` header to `application/json`.

  When the request has the default HTTP method, GET, and the request body is set, this step
  automatically changes HTTP method to POST.

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

      iex> Req.post!("https://httpbin.org/post", json: %{a: 1}).body["json"]
      %{"a" => 1}

  Automatically change GET to POST when body is set:

      iex> Req.request!("https://httpbin.org/post", json: %{a: 1}).body["json"]
      %{"a" => 1}
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
        |> Req.Request.put_header("content-type", multipart.content_type)
        |> then(&maybe_put_content_length(&1, multipart.size))

      data = request.options[:json] ->
        %{request | body: JSON.encode_to_iodata!(data)}
        |> Req.Request.put_new_header("content-type", "application/json")
        |> Req.Request.put_new_header("accept", "application/json")

      true ->
        request
    end
    |> get_to_post()
  end

  defp get_to_post(%Req.Request{method: :get, body: body} = req) when body != nil do
    %{req | method: :post}
  end

  defp get_to_post(req) do
    req
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

  defp put_params(request, new_params) do
    update_in(request.url.query, fn query ->
      old_params = Enum.to_list(URI.query_decoder(query || ""))

      new_params
      |> Enum.reduce(old_params, fn {name, value}, acc ->
        name = to_string(name)
        List.keystore(acc, name, 0, {name, value})
      end)
      |> URI.encode_query()
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

  Not supported with `body: req_body_fun`.

  ## Request Options

    * `:compress_body` - if set to `true`, compresses the request body using gzip.
      Defaults to `false`.

  """
  @doc step: :request
  def compress_body(request) do
    if request.body && request.options[:compress_body] &&
         Req.Request.get_header(request, "content-encoding") == [] do
      body =
        case request.body do
          iodata when is_binary(iodata) or is_list(iodata) ->
            :zlib.gzip(iodata)

          fun when is_function(fun, 1) ->
            raise ArgumentError, "compress_body does not support req_body_fun"

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

    * `:receive_timeout` - socket receive timeout in milliseconds, defaults to `15_000`.

    * `:request_timeout` - response timeout in milliseconds, defaults to `:infinity`.
      See `Finch.request/3`.

    * `:unix_socket` - if set, connect through the given UNIX domain socket.

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

  Response streaming via `Req.stream/4` is supported. Chunks sent with `Plug.Conn.chunk/2`
  are delivered to the streaming function one by one, after the plug returns (the plug runs
  synchronously, so there is no concurrent delivery):

      plug = fn conn ->
        conn = Plug.Conn.send_chunked(conn, 200)
        {:ok, conn} = Plug.Conn.chunk(conn, "foo")
        {:ok, conn} = Plug.Conn.chunk(conn, "bar")
        conn
      end

      Req.stream([plug: plug], [], fn data, _resp, acc -> {:ok, [data | acc]} end)
      #=> {:ok, ["bar", "foo"]}
  """
  @doc step: :request
  def run_plug(request)

  if Code.ensure_loaded?(Plug.Test) do
    def run_plug(request) do
      result =
        case request.body do
          iodata when is_binary(iodata) or is_list(iodata) ->
            {:ok, IO.iodata_to_binary(iodata), request}

          nil ->
            {:ok, "", request}

          req_body_fun when is_function(req_body_fun, 1) ->
            drain_req_body_fun(req_body_fun, request, [])

          enumerable ->
            {:ok, enumerable |> Enum.to_list() |> IO.iodata_to_binary(), request}
        end

      case result do
        {:ok, req_body, request} ->
          run_plug(request, req_body)

        # Halting req_body_fun closes the connection without reading the
        # response, so the plug is never called.
        {:halt, request} ->
          {request, Req.Response.new(status: nil)}
      end
    end

    defp run_plug(request, req_body) do
      plug = request.options.plug

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
        |> Plug.Conn.fetch_query_params(validate_utf8: false)
        |> Plug.Conn.put_private(:req_private, request.private)
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

    defp drain_req_body_fun(req_body_fun, request, chunks) do
      case req_body_fun.(request) do
        {:data, chunk, request} ->
          drain_req_body_fun(req_body_fun, request, [chunk | chunks])

        {:done, request} ->
          {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary(), request}

        {:halt, request} ->
          {:halt, request}

        other ->
          raise "expected req_body_fun to return {:data, chunk, request}, {:done, request}, or {:halt, request}, got: #{inspect(other)}"
      end
    end

    defp handle_plug_result(conn, request) do
      # consume messages sent by Plug.Test adapter
      {Req.Test.Adapter, %{ref: ref, chunks: chunks}} = conn.adapter

      if conn.state == :unset do
        raise """
        expected connection to have a response but no response was set/sent.

        Please verify that you are using Plug.Conn.send_resp/3 in your plug:

            Req.Test.stub(MyStub, fn conn ->
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
          run_plug_stream(conn, request, chunks)

        :self ->
          async = %Req.Response.Async{
            pid: self(),
            ref: make_ref(),
            stream_fun: &plug_parse_message/2,
            cancel_fun: &plug_cancel/1
          }

          resp =
            %{
              Req.Response.new(status: conn.status, headers: conn.resp_headers, body: async)
              | request: request
            }

          for chunk <- chunks || [conn.resp_body] do
            send(self(), {async.ref, {:data, chunk}})
          end

          send(self(), {async.ref, :done})

          case request.stream.(:eof, resp, request.private[:req_stream_acc]) do
            {:ok, resp, _acc} ->
              {request, resp}

            {:error, resp, exception, acc} ->
              {Req.Request.put_private(resp.request, :req_stream_acc, acc), exception}
          end
      end
    end

    defp run_plug_stream(conn, request, chunks) do
      stream = request.stream
      acc = request.private[:req_stream_acc]

      resp =
        %{Req.Response.new(status: conn.status, headers: conn.resp_headers) | request: request}

      result =
        Enum.reduce_while(chunks || [conn.resp_body], {:ok, resp, acc}, fn
          chunk, {:ok, resp, acc} ->
            case stream.(chunk, resp, acc) do
              {:ok, resp, acc} ->
                {:cont, {:ok, resp, acc}}

              {:error, resp, exception, acc} ->
                {:halt, {:error, resp, exception, acc}}
            end
        end)

      case result do
        {:ok, resp, acc} ->
          # The body is done, let the stream decoder flush any buffered data.
          case stream.(:eof, resp, acc) do
            {:ok, resp, acc} ->
              {request, put_in(resp.private[:req_stream_acc], acc)}

            {:error, resp, exception, acc} ->
              {Req.Request.put_private(resp.request, :req_stream_acc, acc), exception}
          end

        {:error, resp, exception, acc} ->
          {Req.Request.put_private(resp.request, :req_stream_acc, acc), exception}
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
            # Hash the raw body in the stream (innermost wrapper, before `decode_body` decodes)
            # and verify at `:eof`.
            %{
              request
              | stream: &checksum_stream_chunk(&1, &2, &3, request.stream, type, checksum)
            }

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
        end
    end
  end

  defp checksum_type("md5:" <> _), do: :md5
  defp checksum_type("sha1:" <> _), do: :sha1
  defp checksum_type("sha256:" <> _), do: :sha256

  defp hash_init(:sha1), do: hash_init(:sha)
  defp hash_init(type), do: :crypto.hash_init(type)

  # The running hash is kept in `resp.private` (not `resp.request.private`, which the adapter
  # resets to the request's private on every chunk).
  defp checksum_stream_chunk(:eof, resp, acc, fun, type, expected) do
    hash = resp.private[:req_checksum_hash] || hash_init(type)
    actual = "#{type}:" <> Base.encode16(:crypto.hash_final(hash), case: :lower, padding: false)

    if expected == actual do
      fun.(:eof, resp, acc)
    else
      {:error, resp, Req.ChecksumMismatchError.exception(expected: expected, actual: actual), acc}
    end
  end

  defp checksum_stream_chunk(data, resp, acc, fun, type, _expected) do
    hash = :crypto.hash_update(resp.private[:req_checksum_hash] || hash_init(type), data)
    fun.(data, put_in(resp.private[:req_checksum_hash], hash), acc)
  end

  @aws_sigv4_excluded_headers [
    # Services like R2 can rewrite this header when
    # encodings it doesn't support are included, i.e. zstd
    "accept-encoding",
    # Trace ID can be rewritten by AWS infrastructure
    "x-amzn-trace-id",
    # Authorization is set by SigV4 itself / not part of canonical request
    "authorization",
    # RFC 2616 Section 13.5.1 "hop-by-hop" headers
    # (list is historical; RFC 7230/9110 use Connection header as the
    # authoritative mechanism, but this enumeration remains the practical baseline)
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailer",
    "transfer-encoding",
    "upgrade"
  ]

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
      headers = Req.Fields.drop(request.headers, @aws_sigv4_excluded_headers)

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
      hash = :crypto.hash_final(config.hash)
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
    if zstd_available?() do
      case zstd_decompress(body) do
        {:ok, decompressed} ->
          decompress_body(rest, decompressed, acc)

        {:error, reason} ->
          %Req.DecompressError{format: :zstd, data: body, reason: reason}
      end
    else
      Logger.debug(
        ":zstd module not available (requires Erlang/OTP 28+), skipping zstd decompression"
      )

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
      |> String.downcase(:ascii)
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
    end)
    |> Enum.reverse()
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

  @builtin_decoders [:json, :json_api, :ndjson, :zip, :tar, :tgz, :gz, :zst, :csv, :event_stream]

  # Build a map of MIME extension (e.g. "json", "json-api") to codec function, so it can be
  # looked up by the extension detected from the response content-type.
  defp build_decoders(request, decoders) do
    for decoder <- decoders, into: %{} do
      {format, codec} = normalize_decoder(request, decoder)
      {decoder_format_name(format), codec}
    end
  end

  # The set of format names (e.g. "json", "event-stream") enabled for this request, taking
  # `:decoders` into account: `nil` falls back to `default`, `false` disables all decoding.
  defp enabled_formats(request, default) do
    decoders =
      case request.options[:decoders] do
        nil -> default
        false -> []
        decoders -> decoders
      end

    for decoder <- decoders, into: MapSet.new(), do: decoder_format_name(decoder)
  end

  defp decoder_format_name({format, _codec}) when is_atom(format), do: decoder_format_name(format)

  defp decoder_format_name(format) when is_atom(format) do
    format |> Atom.to_string() |> String.replace("_", "-")
  end

  defp normalize_decoder(request, format) when is_atom(format) do
    if format in @builtin_decoders do
      {format, builtin_codec(request, format)}
    else
      raise ArgumentError,
            "unknown decoder format: #{inspect(format)}. Built-in formats are: " <>
              Enum.map_join(@builtin_decoders, ", ", &inspect/1) <>
              ". To use a custom format, pass a {format, codec} tuple."
    end
  end

  defp normalize_decoder(request, {format, codec}) when is_atom(format) do
    {format, resolve_codec(request, codec)}
  end

  defp resolve_codec(_request, codec) when is_function(codec, 1) do
    codec
  end

  defp resolve_codec(request, codec) when is_atom(codec) do
    if codec in @builtin_decoders do
      builtin_codec(request, codec)
    else
      # a module exporting decode/1
      &codec.decode/1
    end
  end

  defp builtin_codec(request, format) when format in [:json, :json_api] do
    case Req.Request.fetch_option(request, :decode_json) do
      {:ok, options} ->
        IO.warn(
          "setting `decode_json: options` is deprecated in favour of " <>
            "`decoders: [json: &Jason.decode(&1, options)]`",
          []
        )

        fn body -> Jason.decode(body, options) end

      :error ->
        fn body -> Jason.decode(body) end
    end
  end

  defp builtin_codec(_request, :ndjson), do: &Req.NDJSON.decode/1
  defp builtin_codec(_request, :event_stream), do: &Req.EventStream.decode/1
  defp builtin_codec(_request, :zip), do: &Req.ZIP.decode/1
  defp builtin_codec(_request, :tar), do: &Req.Tar.decode/1
  defp builtin_codec(_request, :tgz), do: &Req.Tar.decode/1
  defp builtin_codec(_request, :gz), do: fn body -> {:ok, :zlib.gunzip(body)} end

  defp builtin_codec(_request, :zst) do
    fn body ->
      case zstd_decompress(body) do
        {:ok, decompressed} ->
          {:ok, decompressed}

        {:error, reason} ->
          {:error,
           %RuntimeError{message: "Could not decompress Zstandard data: #{inspect(reason)}"}}
      end
    end
  end

  defp builtin_codec(_request, :csv) do
    fn body -> {:ok, NimbleCSV.RFC4180.parse_string(body, skip_headers: false)} end
  end

  # Decompresses zstd `body` using the built-in OTP 28+ `:zstd` module. `:zstd.decompress/1`
  # returns iodata and raises `{:zstd_error, reason}` on invalid input.
  defp zstd_decompress(body) do
    {:ok, IO.iodata_to_binary(:zstd.decompress(body))}
  rescue
    e in ErlangError ->
      case e.original do
        {:zstd_error, reason} -> {:error, reason}
        _ -> reraise(e, __STACKTRACE__)
      end
  end

  defp run_decoder(request, response, codec) do
    case codec.(response.body) do
      {:ok, decoded} ->
        {request, put_in(response.body, decoded)}

      {:error, %{__exception__: true} = exception} ->
        {request, exception}

      {:error, reason} ->
        {request, %RuntimeError{message: "decoding response body failed: #{inspect(reason)}"}}
    end
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

  # TODO: remove once `text/event-stream` is registered in MIME (elixir-plug/mime#88).
  defp extensions("text/event-stream" <> _, _path) do
    ["event-stream"]
  end

  defp extensions("application/x-ndjson" <> _, _path) do
    ["ndjson"]
  end

  defp extensions("application/ndjson" <> _, _path) do
    ["ndjson"]
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

  defp redirect_stream_chunk(data_or_eof, resp, acc, fun) do
    cond do
      not redirect_response?(resp) ->
        fun.(data_or_eof, resp, acc)

      data_or_eof == :eof ->
        follow_stream_redirect(resp, acc)

      true ->
        # Discard the redirect response body.
        {:ok, resp, acc}
    end
  end

  defp redirect_response?(resp) do
    resp.status in [301, 302, 303, 307, 308] and
      Req.Response.get_header(resp, "location") != [] and
      Req.Request.get_option(resp.request, :redirect, true) not in [false, nil]
  end

  defp follow_stream_redirect(resp, acc) do
    request = resp.request
    max_redirects = Req.Request.get_option(request, :max_redirects, 10)
    redirect_count = Req.Request.get_private(request, :req_redirect_count, 0)

    if redirect_count < max_redirects do
      # For `into: :self` the redirect's body is already streaming to the caller's mailbox; stop it
      # before issuing the redirected request. No-op for buffered/`Req.stream` bodies.
      with %Req.Response.Async{} <- resp.body do
        Req.cancel_async_response(resp)
      end

      [location | _] = Req.Response.get_header(resp, "location")

      request =
        request
        |> build_redirect_request(resp, location)
        |> Req.Request.put_private(:req_redirect_count, redirect_count + 1)

      # Request steps already ran (and wrapped request.stream), so the new request goes
      # straight to the adapter, reusing the wrapped stream chain. The :eof callback fires
      # after the adapter returned the connection to the pool, so issuing a request here
      # cannot deadlock the pool. The final response (after any further redirects) is threaded
      # back so buffered requests see the redirected response, not the 3xx one.
      case Req.Request.stream_request(request, acc) do
        {:ok, resp, acc} ->
          {:ok, resp, acc}

        {:error, resp, exception, acc} ->
          {:error, resp, exception, acc}
      end
    else
      {:error, resp, %Req.TooManyRedirectsError{max_redirects: max_redirects}, acc}
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

  When streaming the response body via `Req.stream/4`, this step also runs as a request step
  that wraps `request.stream`: chunks of a redirect response are discarded and, once that
  response is done, the redirect is followed the same way as for buffered responses.
  """
  @doc step: :response
  def redirect(request_response)

  def redirect(%Req.Request{stream: nil} = request) do
    request
  end

  def redirect(%Req.Request{stream: fun} = request) when is_function(fun, 3) do
    %{request | stream: &redirect_stream_chunk(&1, &2, &3, fun)}
  end

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
    location = strip_redirect_userinfo(location)
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

  # Userinfo in a redirect location is dropped (and never converted to auth) to avoid silently
  # sending credentials supplied by the redirecting server. Done before logging so it isn't leaked.
  defp strip_redirect_userinfo(location) do
    case URI.parse(location) do
      %URI{userinfo: nil} ->
        location

      %URI{} = uri ->
        Logger.warning("stripping userinfo from redirect location")
        URI.to_string(%{uri | userinfo: nil})
    end
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

  # TODO: deprecate
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

  @doc """
  Expect that response matches the given status.

  This step ensures the HTTP response has the given expected status, otherwise it
  returns `Req.UnexpectedStatusError`.

  ## Request Options

    * `:expect` - the expected HTTP response status. Can be one of the following:

        * integer
        * range
        * atom - one of `:informational` (1xx), `:successful` (2xx), `:redirection` (3xx),
          `:client_error` (4xx), or `:server_error` (5xx)
        * list of integers/ranges/atoms

  > #### Order Matters! {: .info}
  >
  > By default, `expect/1` runs AFTER `retry/1`, `redirect/1`, `decompress_body/1`,
  > and `decode_body/1` steps.
  >
  > This means that, for example, HTTP 503 error would be first retried,
  > HTTP 307 redirect would be first followed, and the response body
  > would be first decompressed and decoded before checking for expected HTTP status.
  > If this is undesirable, re-arrange or disable and manually run given steps.

  > #### Sensitive Response Data {: .warning}
  >
  > This step returns `Req.UnexpectedStatusError` which contains full `Req.Response`.
  > Since response headers/body can contain sensitive data, be careful about raising
  > this error and automatically logging it, sending to exception trackers, etc.

  This step handles both buffered and streamed response bodies:

    * On regular requests, it runs as a response step and checks `response.status`.

    * When the response body is streamed via `Req.stream/4`, it runs as a request step
      that wraps `request.stream`. As soon as the status is known not to match, streaming
      stops with `Req.UnexpectedStatusError` and the user function never receives any
      body chunks. Redirects are still followed first. The error contains the response
      with status and headers but, since the body was streamed, no body.

  ## Examples

      iex> resp = Req.get!("https://httpbin.org/status/200", expect: 200)
      iex> resp.status
      200

      iex> Req.get!("https://httpbin.org/status/404", expect: 200..299)
      ** (Req.UnexpectedStatusError) expected status 200..299, got: 404

      iex> {:error, e} = Req.get("https://httpbin.org/status/404", expect: 200..299)
      iex> e.expected_status
      200..299
      iex> e.response.status
      404
  """
  @doc step: :request
  def expect(request_or_request_response)

  def expect(%Req.Request{stream: nil} = request) do
    request
  end

  def expect(%Req.Request{stream: fun} = request) when is_function(fun, 3) do
    if request.options[:expect] do
      %{request | stream: &expect_stream_chunk(&1, &2, &3, fun)}
    else
      request
    end
  end

  def expect({request, response}) do
    if expect = request.options[:expect] do
      if expect_success?(response.status, expect) do
        {request, response}
      else
        {request,
         Req.UnexpectedStatusError.exception(expected_status: expect, response: response)}
      end
    else
      {request, response}
    end
  end

  defp expect_stream_chunk(data_or_eof, resp, acc, fun) do
    expect = resp.request.options[:expect]

    if expect_success?(resp.status, expect) do
      fun.(data_or_eof, resp, acc)
    else
      exception = Req.UnexpectedStatusError.exception(expected_status: expect, response: resp)
      {:error, resp, exception, acc}
    end
  end

  defp expect_success?(status, status) do
    true
  end

  defp expect_success?(_, other_status) when is_integer(other_status) do
    false
  end

  defp expect_success?(status, %Range{} = statuses) do
    status in statuses
  end

  @status_category_atoms [:informational, :successful, :redirection, :client_error, :server_error]

  defp expect_success?(status, :informational), do: status in 100..199
  defp expect_success?(status, :successful), do: status in 200..299
  defp expect_success?(status, :redirection), do: status in 300..399
  defp expect_success?(status, :client_error), do: status in 400..499
  defp expect_success?(status, :server_error), do: status in 500..599

  defp expect_success?(status, [expect | tail])
       when is_integer(expect) or is_struct(expect, Range) or expect in @status_category_atoms do
    if expect_success?(status, expect) do
      true
    else
      expect_success?(status, tail)
    end
  end

  defp expect_success?(_status, []) do
    false
  end

  ## Error steps

  @doc """
  Retries a request in face of errors.

  This function can be used as either or both response and error step.

  When streaming the response body via `Req.stream/4`, this step also runs as a request step that
  wraps `request.stream`: a retryable response (by status code) has its body chunks discarded and,
  once done, the request is re-issued. A transport error mid-stream is not retried, as body chunks
  may already have been delivered to the streaming function.

  ## Request Options

    * `:retry` - can be one of the following:

        * `:safe_transient` (default) - retry safe (GET/HEAD) requests on one of:

            * HTTP 408/429/500/502/503/504 responses

            * `Req.TransportError` with `reason: :timeout | :econnrefused | :closed`

            * `Req.HTTPError` with `protocol: :http2, reason: :unprocessed | :pool_not_available`

        * `:transient` - same as `:safe_transient` except retries all HTTP methods (POST, DELETE, etc.)

        * `fun` - a 2-arity function that accepts a `Req.Request` and either a `Req.Response` or an exception struct
          and returns one of the following:

            * `true` - retry with the default delay controller by default delay option described below.

            * `{:delay, milliseconds}` - retry with the given delay.

            * `false/nil` - don't retry.

        * `false` - don't retry.

    * `:retry_delay` - if not set, which is the default, the retry delay is determined by
      the value of the `Retry-After` header on HTTP 429/503 responses. If the header is not set,
      or the header value is negative, the default delay follows a simple exponential backoff
      with jitter, for example: 0.949s, 1.97s, 3.87s, 7.55s, ...

      `:retry_delay` can be set to a function that receives the retry count (starting at 0)
      and returns the delay, the number of milliseconds to sleep before making another attempt.

    * `:retry_log_level` - the log level to emit retry logs at. Can also be set to `false` to disable
      logging these messages. Defaults to `:warning`.

    * `:max_retries` - maximum number of retry attempts, defaults to `3` (for a total of `4`
      requests to the server, including the initial one.)

  ## Examples

      iex> Req.get!("https://httpbin.org/status/500,200").status
      # 08:43:19.101 [warning] retry: got response with status 500, will retry in 941ms, 2 attempts left
      # 08:43:22.958 [warning] retry: got response with status 500, will retry in 1877ms, 1 attempt left
      200

  """
  @doc step: :error
  def retry(request_response_or_error)

  def retry(%Req.Request{stream: nil} = request) do
    request
  end

  def retry(%Req.Request{stream: fun} = request) when is_function(fun, 3) do
    %{request | stream: &retry_stream_chunk(&1, &2, &3, fun)}
  end

  def retry({request, response_or_exception}) do
    case retry_decision(request, response_or_exception) do
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

  defp retry_decision(request, response_or_exception) do
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
  end

  # Streaming (`Req.stream/4`) retry. Response steps don't run for streamed responses, so this
  # request-step wrapper intercepts a retryable response at the stream level: its body chunks are
  # discarded and, once done, the request is re-issued via `Req.Request.stream_request/2`, the same
  # way `redirect/1` handles streamed redirects. Only retryable *statuses* are handled here; a
  # transport error mid-stream is not retried, since body chunks may already have been delivered.
  defp retry_stream_chunk(data_or_eof, resp, acc, fun) do
    cond do
      not retry_response?(resp) ->
        fun.(data_or_eof, resp, acc)

      data_or_eof == :eof ->
        stream_retry(resp, acc)

      true ->
        # Discard the body of a response we are going to retry.
        {:ok, resp, acc}
    end
  end

  defp retry_response?(resp) do
    case resp.status do
      status when status in [408, 429, 500, 502, 503, 504] ->
        request = resp.request
        retry_count = Req.Request.get_private(request, :req_retry_count, 0)
        max_retries = Req.Request.get_option(request, :max_retries, 3)

        retry_count < max_retries and retry_decision(request, resp) not in [false, nil]

      _ ->
        false
    end
  end

  defp stream_retry(resp, acc) do
    request = resp.request
    retry_count = Req.Request.get_private(request, :req_retry_count, 0)

    {request, delay} =
      case retry_decision(request, resp) do
        {:delay, delay} ->
          if Req.Request.get_option(request, :retry_delay) do
            raise ArgumentError,
                  "expected :retry_delay not to be set when the :retry function is returning `{:delay, milliseconds}`"
          end

          {request, delay}

        _ ->
          get_retry_delay(request, resp, retry_count)
      end

    max_retries = Req.Request.get_option(request, :max_retries, 3)
    log_level = Req.Request.get_option(request, :retry_log_level, :warning)
    log_retry(resp, retry_count, max_retries, delay, log_level)
    Process.sleep(delay)
    request = Req.Request.put_private(request, :req_retry_count, retry_count + 1)

    # For `into: :self` the body being retried is streaming to the caller's mailbox; stop it before
    # retrying. No-op for buffered/`Req.stream` bodies.
    with %Req.Response.Async{} <- resp.body do
      Req.cancel_async_response(resp)
    end

    case Req.Request.stream_request(request, acc) do
      {:ok, resp, acc} ->
        {:ok, resp, acc}

      {:error, resp, exception, acc} ->
        {:error, resp, exception, acc}
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

  defp transient?(%Req.HTTPError{protocol: :http2, reason: reason})
       when reason in [:unprocessed, :pool_not_available] do
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
    case Req.Request.get_option(request, :retry_delay, &exp_backoff_with_jitter/1) do
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

  defp exp_backoff_with_jitter(n) do
    trunc(Integer.pow(2, n) * 1000 * (1 - 0.1 * :rand.uniform()))
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
