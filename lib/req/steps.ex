defmodule Req.Steps do
  @moduledoc """
  A collection of built-in steps.

  Req is composed of:

    * `Req` - the high-level API

    * `Req.Request` - the low-level API and the request struct

    * `Req.Auth`, …, `Req.Steps` - a collection of built-in steps (you're here!)

    * `Req.Test` - the testing conveniences

  See also step modules:

    * `Req.Auth`

    * `Req.Checksum`

    * `Req.Decode`

    * `Req.Decompress`

    * `Req.Expect`

    * `Req.Into`

    * `Req.Redirect`

    * `Req.Retry`
  """

  @doc false
  def __default__ do
    [
      expect: Req.Expect,
      retry: Req.Retry,
      decode: Req.Decode,
      into: Req.Into,
      checksum: Req.Checksum,
      decompress: Req.Decompress,
      redirect: Req.Redirect,
      put_user_agent: &Req.Steps.put_user_agent/1,
      encode_body: &Req.Steps.encode_body/1,
      put_base_url: &Req.Steps.put_base_url/1,
      auth: Req.Auth,
      put_params: &Req.Steps.put_params/1,
      put_path_params: &Req.Steps.put_path_params/1,
      put_range: &Req.Steps.put_range/1,
      compress_body: &Req.Steps.compress_body/1,
      put_aws_sigv4: &Req.Steps.put_aws_sigv4/1
    ]
  end

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
      :expect,
      :http_errors,
      :decode_body,
      :decoders,
      :decode_json,
      :redirect,
      :redirect_trusted,
      :redirect_log_level,
      :max_redirects,
      :retry,
      :retry_delay,
      :retry_log_level,
      :max_retries,
      :plug,
      :finch,
      :finch_private,
      :connect_options,
      :inet6,
      :request_timeout,
      :receive_timeout,
      :pool_timeout,
      :unix_socket,
      :pool_max_idle_time,

      # TODO: Remove on Req 1.0
      :follow_redirects,
      :location_trusted,
      :redact_auth
    ])
    |> Req.Request.prepend_request_steps(__default__())
  end

  ## Request steps

  @doc """
  Sets base URL for all requests.

  ## Request Options

    * `:base_url` - if set, the request URL is merged with this base URL.

      The base url can be a string, a `%URI{}` struct, a 0-arity function,
      or a `{mod, fun, args}` tuple describing a function to call.

  ## Examples

      iex> req = Req.new(base_url: "https://httpbingo.org")
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

  @user_agent "req/#{Mix.Project.config()[:version]}"

  @doc """
  Sets the user-agent header.

  ## Request Options

    * `:user_agent` - sets the `user-agent` header. Defaults to `"#{@user_agent}"`.

  ## Examples

      iex> Req.get!("https://httpbingo.org/user-agent").body
      %{"user-agent" => "#{@user_agent}"}

      iex> Req.get!("https://httpbingo.org/user-agent", user_agent: "foo").body
      %{"user-agent" => "foo"}
  """
  @doc step: :request
  def put_user_agent(request) do
    user_agent = Req.Request.get_option(request, :user_agent, @user_agent)
    Req.Request.put_new_header(request, "user-agent", user_agent)
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

      iex> Req.post!("https://httpbingo.org/anything", form: [a: 1]).body["form"]
      %{"a" => ["1"]}

  Encoding form (`multipart/form-data`):

      iex> fields = [a: 1, b: {"2", filename: "b.txt"}]
      iex> resp = Req.post!("https://httpbingo.org/anything", form_multipart: fields)
      iex> resp.body["form"]
      %{"a" => ["1"]}
      iex> resp.body["files"]
      %{"b" => ["2"]}

  Encoding streaming form (`multipart/form-data`):

      iex> stream = Stream.cycle(["abc"]) |> Stream.take(3)
      iex> fields = [file: {stream, filename: "b.txt"}]
      iex> resp = Req.post!("https://httpbingo.org/anything", form_multipart: fields)
      iex> resp.body["files"]
      %{"file" => ["abcabcabc"]}

      # with explicit :size
      iex> stream = Stream.cycle(["abc"]) |> Stream.take(3)
      iex> fields = [file: {stream, filename: "b.txt", size: 9}]
      iex> resp = Req.post!("https://httpbingo.org/anything", form_multipart: fields)
      iex> resp.body["files"]
      %{"file" => ["abcabcabc"]}

  Encoding JSON:

      iex> Req.post!("https://httpbingo.org/post", json: %{a: 1}).body["json"]
      %{"a" => 1}

  Automatically change GET to POST when body is set:

      iex> Req.request!("https://httpbingo.org/post", json: %{a: 1}).body["json"]
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
  `:code` in `https://httpbingo.org/status/:code`. If you want to use the `{code}` syntax,
  set `path_params_style: :curly`. Param names must start with a letter and can contain letters,
  digits, and underscores; this is true both for `:colon_params` as well as `{curly_params}`.

  Path params are replaced in the request URL path. The path params are specified as a keyword
  list of parameter names and values, as in the examples below. The values of the parameters are
  converted to strings using the `String.Chars` protocol (`to_string/1`).

  ## Request Options

    * `:path_params` - if set, params to add to the templated path. Defaults to `nil`.

    * `:path_params_style` (*available since v0.5.1*) - how path params are expressed. Can be one of:

         * `:colon` - (default) for Plug-style parameters, such as `:code` in
           `https://httpbingo.org/status/:code`.

         * `:curly` - for [OpenAPI](https://swagger.io/specification/)-style parameters, such as
           `{code}` in `https://httpbingo.org/status/{code}`.

  ## Examples

      iex> Req.get!("https://httpbingo.org/status/:code", path_params: [code: 201]).status
      201

      iex> Req.get!("https://httpbingo.org/status/{code}", path_params: [code: 201], path_params_style: :curly).status
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
    template = Req.Request.get_private(request, :path_params_template, request.url.path)

    request
    |> Req.Request.put_private(:path_params_template, template)
    |> then(&put_in(&1.url.path, template))
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

      iex> Req.get!("https://httpbingo.org/anything/query", params: [x: 1, y: 2]).body["args"]
      %{"x" => ["1"], "y" => ["2"]}

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

      iex> response = Req.get!("https://httpbingo.org/range/100", range: 0..3)
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
            Req.Gzip.encode_to_iodata(iodata)

          fun when is_function(fun, 1) ->
            raise ArgumentError, "compress_body does not support req_body_fun"

          enumerable ->
            Req.Gzip.encode_to_stream(enumerable)
        end

      request
      |> Map.replace!(:body, body)
      |> Req.Request.put_header("content-encoding", "gzip")
    else
      request
    end
  end

  @aws_sigv4_excluded_headers [
    # Services like R2 can rewrite this header when
    # encodings it doesn't support are included, i.e. zstd
    "accept-encoding",
    # Trace ID can be rewritten by AWS infrastructure
    "x-amzn-trace-id",
    # Authorization is set by SigV4 itself / not part of canonical request
    "authorization",
    # Excluded by botocore's SigV4 signer and rejected by e.g. Supabase Storage
    "expect",
    "user-agent",
    # Rejected by e.g. Supabase Storage
    "from",
    "max-forwards",
    "pragma",
    "referer",
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
      iex> %{status: 200} = Req.put!(req, url: "/bucket1/key1", headers: [content_length: size], body: stream)
      iex> byte_size(Req.get!(req, url: "/bucket1/key1").body)
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
      headers = Req.Fields.get_list(headers)

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
end
