defmodule Req.Utils do
  @moduledoc false

  defmacrop iodata({:<<>>, _, parts}) do
    Enum.map(parts, &to_iodata/1)
  end

  defp to_iodata(binary) when is_binary(binary) do
    binary
  end

  defp to_iodata(
         {:"::", _, [{{:., _, [Kernel, :to_string]}, _, [interpolation]}, {:binary, _, nil}]}
       ) do
    interpolation
  end

  @doc """
  Create AWS Signature v4.

  https://docs.aws.amazon.com/AmazonS3/latest/API/sig-v4-header-based-auth.html
  """
  def aws_sigv4_headers(options) do
    {access_key_id, options} = Keyword.pop!(options, :access_key_id)
    {secret_access_key, options} = Keyword.pop!(options, :secret_access_key)
    {security_token, options} = Keyword.pop(options, :token)
    {region, options} = Keyword.pop!(options, :region)
    {service, options} = Keyword.pop!(options, :service)
    {datetime, options} = Keyword.pop!(options, :datetime)
    {method, options} = Keyword.pop!(options, :method)
    {url, options} = Keyword.pop!(options, :url)
    {headers, options} = Keyword.pop!(options, :headers)
    {body, options} = Keyword.pop!(options, :body)
    Keyword.validate!(options, [:body_digest])

    datetime = DateTime.truncate(datetime, :second)
    datetime_string = DateTime.to_iso8601(datetime, :basic)
    date_string = Date.to_iso8601(datetime, :basic)
    url = normalize_url(url)
    body_digest = options[:body_digest] || hex(sha256(body))
    service = to_string(service)

    method = method |> Atom.to_string() |> String.upcase()

    headers = canonical_host_header(headers, url)

    aws_headers = [
      {"x-amz-content-sha256", body_digest},
      {"x-amz-date", datetime_string}
    ]

    aws_headers =
      if security_token do
        aws_headers ++ [{"x-amz-security-token", security_token}]
      else
        aws_headers
      end

    canonical_headers = headers ++ aws_headers

    ## canonical_headers needs to be sorted for canonical_request construction
    canonical_headers = Enum.sort(canonical_headers)

    signed_headers =
      Enum.map_intersperse(
        Enum.sort(canonical_headers),
        ";",
        &String.downcase(elem(&1, 0), :ascii)
      )

    canonical_headers =
      Enum.map_intersperse(canonical_headers, "\n", fn {name, value} -> [name, ":", value] end)

    path = URI.encode(url.path || "/", &(&1 == ?/ or URI.char_unreserved?(&1)))

    canonical_query = canonical_query(url.query)

    canonical_request = """
    #{method}
    #{path}
    #{canonical_query}
    #{canonical_headers}

    #{signed_headers}
    #{body_digest}\
    """

    string_to_sign =
      iodata("""
      AWS4-HMAC-SHA256
      #{datetime_string}
      #{date_string}/#{region}/#{service}/aws4_request
      #{hex(sha256(canonical_request))}\
      """)

    signature =
      aws_sigv4(
        string_to_sign,
        date_string,
        region,
        service,
        secret_access_key
      )

    credential = "#{access_key_id}/#{date_string}/#{region}/#{service}/aws4_request"

    authorization =
      "AWS4-HMAC-SHA256 Credential=#{credential},SignedHeaders=#{signed_headers},Signature=#{signature}"

    [{"authorization", authorization}] ++ aws_headers ++ headers
  end

  defp canonical_query(query) when query in [nil, ""] do
    query
  end

  defp canonical_query(query) do
    for item <- String.split(query, "&", trim: true) do
      case String.split(item, "=") do
        [name, value] -> [name, "=", value]
        [name] -> [name, "="]
      end
    end
    |> Enum.sort()
    |> Enum.intersperse("&")
  end

  @doc """
  Create AWS Signature v4 URL.

  https://docs.aws.amazon.com/AmazonS3/latest/API/sigv4-query-string-auth.html
  """
  def aws_sigv4_url(options) do
    {access_key_id, options} = Keyword.pop!(options, :access_key_id)
    {secret_access_key, options} = Keyword.pop!(options, :secret_access_key)
    {region, options} = Keyword.pop!(options, :region)
    {service, options} = Keyword.pop!(options, :service)
    {datetime, options} = Keyword.pop!(options, :datetime)
    {method, options} = Keyword.pop!(options, :method)
    {url, options} = Keyword.pop!(options, :url)
    {expires, options} = Keyword.pop(options, :expires, 86400)
    {headers, options} = Keyword.pop(options, :headers, [])
    {query, options} = Keyword.pop(options, :query, [])
    [] = options

    datetime = DateTime.truncate(datetime, :second)
    datetime_string = DateTime.to_iso8601(datetime, :basic)
    date_string = Date.to_iso8601(datetime, :basic)
    url = normalize_url(url)
    service = to_string(service)

    canonical_headers =
      headers
      |> canonical_host_header(url)
      |> format_canonical_headers()

    signed_headers = Enum.map_join(canonical_headers, ";", &elem(&1, 0))

    canonical_query_string =
      format_canonical_query_params(
        [
          {"X-Amz-Algorithm", "AWS4-HMAC-SHA256"},
          {"X-Amz-Credential",
           "#{access_key_id}/#{date_string}/#{region}/#{service}/aws4_request"},
          {"X-Amz-Date", datetime_string},
          {"X-Amz-Expires", expires},
          {"X-Amz-SignedHeaders", signed_headers}
        ] ++ query
      )

    path = URI.encode(url.path || "/", &(&1 == ?/ or URI.char_unreserved?(&1)))

    true = url.query in [nil, ""]

    method = method |> Atom.to_string() |> String.upcase()

    canonical_headers =
      Enum.map_intersperse(canonical_headers, "\n", fn {name, value} -> [name, ":", value] end)

    canonical_request = """
    #{method}
    #{path}
    #{canonical_query_string}
    #{canonical_headers}

    #{signed_headers}
    UNSIGNED-PAYLOAD\
    """

    string_to_sign =
      iodata("""
      AWS4-HMAC-SHA256
      #{datetime_string}
      #{date_string}/#{region}/#{service}/aws4_request
      #{hex(sha256(canonical_request))}\
      """)

    signature =
      aws_sigv4(
        string_to_sign,
        date_string,
        region,
        service,
        secret_access_key
      )

    %{url | path: path, query: canonical_query_string <> "&X-Amz-Signature=#{signature}"}
  end

  # Try decoding the path in case it was encoded earlier to prevent double encoding,
  # as the path is encoded later in the corresponding function.
  defp normalize_url(url) do
    url = URI.parse(url)

    case url.path do
      nil -> url
      path -> %{url | path: URI.decode(path)}
    end
  end

  defp canonical_host_header(headers, %URI{} = url) do
    {_host_headers, headers} = Enum.split_with(headers, &match?({"host", _value}, &1))

    host_value =
      if is_nil(url.port) or URI.default_port(url.scheme) == url.port do
        url.host
      else
        "#{url.host}:#{url.port}"
      end

    [{"host", host_value} | headers]
  end

  # Headers must be sorted alphabetically by name
  # Header names must be lower case
  # Header values must be trimmed
  # See https://docs.aws.amazon.com/AmazonS3/latest/API/sig-v4-header-based-auth.html
  defp format_canonical_headers(headers) do
    headers
    |> Enum.map(&format_canonical_header/1)
    |> Enum.sort(fn {name_1, _}, {name_2, _} -> name_1 < name_2 end)
  end

  defp format_canonical_header({name, value}) do
    name =
      name
      |> to_string()
      |> String.downcase(:ascii)

    value =
      value
      |> to_string()
      |> String.trim()

    {name, value}
  end

  # Query params must be sorted alphabetically by name
  # Query param name and values must be URI-encoded individually
  # Query params must be sorted after encoding
  # See https://docs.aws.amazon.com/AmazonS3/latest/API/sig-v4-header-based-auth.html
  defp format_canonical_query_params(query_params) do
    query_params
    |> Enum.map(&format_canonical_query_param/1)
    |> Enum.sort(&canonical_query_param_sorter/2)
    |> Enum.map_join("&", fn {name, value} -> "#{name}=#{value}" end)
  end

  # Spaces must be encoded as %20, not as "+".
  defp format_canonical_query_param({name, value}) do
    name =
      name
      |> to_string()
      |> URI.encode(&URI.char_unreserved?/1)

    value =
      value
      |> to_string()
      |> URI.encode(&URI.char_unreserved?/1)

    {name, value}
  end

  defp canonical_query_param_sorter({name, value_1}, {name, value_2}), do: value_1 < value_2
  defp canonical_query_param_sorter({name_1, _}, {name_2, _}), do: name_1 < name_2

  def aws_sigv4(
        string_to_sign,
        date_string,
        region,
        service,
        secret_access_key
      ) do
    signature =
      ["AWS4", secret_access_key]
      |> hmac(date_string)
      |> hmac(region)
      |> hmac(service)
      |> hmac("aws4_request")
      |> hmac(string_to_sign)
      |> hex()

    signature
  end

  defp hex(data) do
    Base.encode16(data, case: :lower)
  end

  defp sha256(data) do
    :crypto.hash(:sha256, data)
  end

  defp hmac(key, data) do
    :crypto.mac(:hmac, :sha256, key, data)
  end

  @doc """
  Formats a datetime as "HTTP Date".

  ## Examples

      iex> Req.Utils.format_http_date(~U[2024-01-01 09:00:00Z])
      "Mon, 01 Jan 2024 09:00:00 GMT"
  """
  def format_http_date(datetime) do
    Calendar.strftime(datetime, "%a, %d %b %Y %H:%M:%S GMT")
  end

  @doc """
  Parses "HTTP Date" as datetime.

  ## Examples

      iex> Req.Utils.parse_http_date("Mon, 01 Jan 2024 09:00:00 GMT")
      {:ok, ~U[2024-01-01 09:00:00Z]}
  """
  def parse_http_date(<<
        day_name::binary-size(3),
        ", ",
        day::binary-size(2),
        " ",
        month_name::binary-size(3),
        " ",
        year::binary-size(4),
        " ",
        time::binary-size(8),
        " GMT"
      >>) do
    with {:ok, day_of_week} <- parse_day_name(day_name),
         {day, ""} <- Integer.parse(day),
         {:ok, month} <- parse_month_name(month_name),
         {year, ""} <- Integer.parse(year),
         {:ok, time} <- Time.from_iso8601(time),
         {:ok, date} <- Date.new(year, month, day),
         true <- day_of_week == Date.day_of_week(date) do
      DateTime.new(date, time)
    else
      {:error, _} = e ->
        e

      _ ->
        {:error, :invalid_format}
    end
  end

  def parse_http_date(binary) when is_binary(binary) do
    {:error, :invalid_format}
  end

  defp parse_month_name("Jan"), do: {:ok, 1}
  defp parse_month_name("Feb"), do: {:ok, 2}
  defp parse_month_name("Mar"), do: {:ok, 3}
  defp parse_month_name("Apr"), do: {:ok, 4}
  defp parse_month_name("May"), do: {:ok, 5}
  defp parse_month_name("Jun"), do: {:ok, 6}
  defp parse_month_name("Jul"), do: {:ok, 7}
  defp parse_month_name("Aug"), do: {:ok, 8}
  defp parse_month_name("Sep"), do: {:ok, 9}
  defp parse_month_name("Oct"), do: {:ok, 10}
  defp parse_month_name("Nov"), do: {:ok, 11}
  defp parse_month_name("Dec"), do: {:ok, 12}
  defp parse_month_name(_), do: :error

  defp parse_day_name("Mon"), do: {:ok, 1}
  defp parse_day_name("Tue"), do: {:ok, 2}
  defp parse_day_name("Wed"), do: {:ok, 3}
  defp parse_day_name("Thu"), do: {:ok, 4}
  defp parse_day_name("Fri"), do: {:ok, 5}
  defp parse_day_name("Sat"), do: {:ok, 6}
  defp parse_day_name("Sun"), do: {:ok, 7}
  defp parse_day_name(_), do: :error

  @doc """
  Parses "HTTP Date" as datetime or raises an error.

  ## Examples

      iex> Req.Utils.parse_http_date!("Mon, 01 Jan 2024 09:00:00 GMT")
      ~U[2024-01-01 09:00:00Z]

      iex> Req.Utils.parse_http_date!("Mon")
      ** (ArgumentError) cannot parse "Mon" as HTTP date, reason: :invalid_format
  """
  def parse_http_date!(binary) do
    case parse_http_date(binary) do
      {:ok, datetime} ->
        datetime

      {:error, reason} ->
        raise ArgumentError,
              "cannot parse #{inspect(binary)} as HTTP date, reason: #{inspect(reason)}"
    end
  end

  @doc """
  Returns a stream where each element is gzipped.

  ## Examples

      iex> gzipped = Req.Utils.stream_gzip(~w[foo bar baz]) |> Enum.to_list()
      iex> :zlib.gunzip(gzipped)
      "foobarbaz"
  """
  def stream_gzip(enumerable) do
    Stream.transform(
      enumerable,
      # start_fun
      fn ->
        z = :zlib.open()
        # copied from :zlib.gzip/1
        :ok = :zlib.deflateInit(z, :default, :deflated, 16 + 15, 8, :default)
        z
      end,
      # reducer
      fn chunk, z ->
        case :zlib.deflate(z, chunk) do
          # optimization: avoid emitting empty chunks
          [] -> {[], z}
          compressed -> {[compressed], z}
        end
      end,
      # last_fun
      fn z ->
        last = :zlib.deflate(z, [], :finish)
        :ok = :zlib.deflateEnd(z)
        {[last], z}
      end,
      # after_fun
      fn z -> :ok = :zlib.close(z) end
    )
  end

  defmodule CollectWithHash do
    @moduledoc false

    defstruct [:collectable, :type]

    defimpl Collectable do
      def into(%{collectable: collectable, type: type}) do
        {acc, collector} = Collectable.into(collectable)

        new_collector = fn
          {acc, hash}, {:cont, element} ->
            hash = :crypto.hash_update(hash, element)
            {collector.(acc, {:cont, element}), hash}

          {acc, hash}, :done ->
            hash = :crypto.hash_final(hash)
            {collector.(acc, :done), hash}

          {acc, hash}, :halt ->
            {collector.(acc, :halt), hash}
        end

        hash = hash_init(type)
        {{acc, hash}, new_collector}
      end

      defp hash_init(:sha1), do: :crypto.hash_init(:sha)
      defp hash_init(type), do: :crypto.hash_init(type)
    end
  end

  @doc """
  Returns a collectable with hash.

  ## Examples

      iex> collectable = Req.Utils.collect_with_hash([], :md5)
      iex> Enum.into(Stream.duplicate("foo", 2), collectable)
      {~w[foo foo], :erlang.md5("foofoo")}
  """
  def collect_with_hash(collectable, type) do
    %CollectWithHash{collectable: collectable, type: type}
  end

  @crlf "\r\n"

  @doc """
  Encodes fields into "multipart/form-data" format.
  """
  def encode_form_multipart(fields, options \\ []) do
    options = Keyword.validate!(options, [:boundary])

    boundary =
      options[:boundary] ||
        Base.encode16(:crypto.strong_rand_bytes(16), padding: false, case: :lower)

    footer = [["--", boundary, "--", @crlf]]

    {body, size} =
      fields
      |> Enum.reduce({[], 0}, &add_form_parts(&2, encode_form_part(&1, boundary)))
      |> add_form_parts({footer, IO.iodata_length(footer)})

    %{
      size: size,
      content_type: "multipart/form-data; boundary=#{boundary}",
      body: body
    }
  end

  defp add_sizes(_, nil), do: nil
  defp add_sizes(nil, _), do: nil
  defp add_sizes(size1, size2), do: size1 + size2

  defp add_form_parts({parts1, size1}, {parts2, size2})
       when is_list(parts1) and is_list(parts2) do
    {[parts1, parts2], add_sizes(size1, size2)}
  end

  defp add_form_parts({parts1, size1}, {parts2, size2}) do
    {Stream.concat(parts1, parts2), add_sizes(size1, size2)}
  end

  defp encode_form_part({name, {value, options}}, boundary) do
    options = Keyword.validate!(options, [:filename, :content_type, :size])

    {parts, parts_size, options} =
      case value do
        integer when is_integer(integer) ->
          part = Integer.to_string(integer)
          {[part], byte_size(part), options}

        value when is_binary(value) or is_list(value) ->
          {[value], IO.iodata_length(value), options}

        stream = %File.Stream{} ->
          filename = Path.basename(stream.path)

          # TODO: Simplify when we require Elixir v1.15
          size =
            if not Map.has_key?(stream, :node) or stream.node == node() do
              File.stat!(stream.path).size
            else
              :erpc.call(stream.node, fn -> File.stat!(stream.path).size end)
            end

          options =
            options
            |> Keyword.put_new(:filename, filename)
            |> Keyword.put_new_lazy(:content_type, fn ->
              MIME.from_path(filename)
            end)

          {stream, size, options}

        enum ->
          size = Keyword.get(options, :size)

          {enum, size, options}
      end

    params =
      if filename = options[:filename] do
        ["; filename=\"", filename, "\""]
      else
        []
      end

    headers =
      if content_type = options[:content_type] do
        ["content-type: ", content_type, @crlf]
      else
        []
      end

    headers = ["content-disposition: form-data; name=\"#{name}\"", params, @crlf, headers]
    header = [["--", boundary, @crlf, headers, @crlf]]

    {header, IO.iodata_length(header)}
    |> add_form_parts({parts, parts_size})
    |> add_form_parts({[@crlf], 2})
  end

  defp encode_form_part({name, value}, boundary) do
    encode_form_part({name, {value, []}}, boundary)
  end

  @doc """
  Loads .netrc file.

  ## Examples

      iex> {:ok, pid} = StringIO.open(\"""
      ...> machine localhost
      ...> login foo
      ...> password bar
      ...> \""")
      iex> Req.Utils.load_netrc(pid)
      %{"localhost" => {"foo", "bar"}}
  """
  def load_netrc(path_or_device) do
    case read_netrc(path_or_device) do
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

  defp read_netrc(path) when is_binary(path) do
    File.read(path)
  end

  defp read_netrc(pid) when is_pid(pid) do
    <<content::binary>> = IO.read(pid, :eof)
    {:ok, content}
  end

  defp parse_netrc(credentials), do: parse_netrc(credentials, %{})

  defp parse_netrc([], acc), do: acc

  defp parse_netrc([_, machine, _, login, _, password | tail], acc) do
    acc = Map.put(acc, String.trim(machine), {String.trim(login), String.trim(password)})
    parse_netrc(tail, acc)
  end

  defp parse_netrc(_, _), do: raise("error parsing .netrc file")

  @doc """
  Parses HTTP Digest authentication header (RFC 7616).

  ## Examples

      iex> Req.Utils.parse_http_digest(~s(Digest realm="example", nonce="abc123", qop="auth"))
      %{"realm" => "example", "nonce" => "abc123", "qop" => "auth"}

  """
  def parse_http_digest("Digest " <> rest) do
    rest
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Map.new(&parse_digest_header_part/1)
  end

  @doc """
  Generates HTTP Digest authentication header (RFC 7616).

  Takes a challenge header from the server's `WWW-Authenticate` response and generates
  the corresponding `Authorization` header value for digest authentication.

  Returns `{:ok, header_value}` on success or `{:error, reason}` on failure.

  ## Options

    * `:count` - The nonce count (default: 1). Used for tracking request count with same nonce.

  ## Examples

      challenge = ~s(Digest realm="example", nonce="abc123", qop="auth")
      {:ok, value} = Req.Utils.http_digest_auth(challenge, "user", "pass", :get, "/path")
      #=> {:ok, "Digest response=..."}
  """
  def http_digest_auth(challenge_header, username, password, method, uri, opts \\ []) do
    count = Keyword.get(opts, :count, 1)
    challenge = parse_http_digest(challenge_header)
    generate_digest_auth_header(challenge, username, password, method, uri, count)
  end

  defp parse_digest_header_part(part) do
    case String.split(part, "=", parts: 2) do
      [key, value] ->
        {String.trim(key), unquote_digest_value(value)}

      [key] ->
        {String.trim(key), ""}
    end
  end

  defp unquote_digest_value(value) do
    value = String.trim(value)

    if String.starts_with?(value, ~s(")) and String.ends_with?(value, ~s(")) do
      value
      |> String.slice(1..-2//1)
      |> Macro.unescape_string()
    else
      value
    end
  end

  defp quote_digest_value(str) when is_binary(str) do
    inspect(str, printable_limit: :infinity)
  end

  defp digest_count_to_nc(count) do
    String.pad_leading(Integer.to_string(count, 16), 8, "0")
  end

  defp generate_digest_auth_header(challenge, username, password, method, uri, count) do
    algorithm = Map.get(challenge, "algorithm", "MD5")
    realm = Map.get(challenge, "realm", "")
    nonce = Map.get(challenge, "nonce", "")
    opaque = Map.get(challenge, "opaque")
    qop = Map.get(challenge, "qop")
    cnonce = generate_digest_cnonce()
    nc = digest_count_to_nc(count)

    with {:ok, hash_func, sess?} <- digest_hash_function(algorithm) do
      ha1 = hash_func.("#{username}:#{realm}:#{password}")

      ha1 =
        if sess? do
          hash_func.("#{ha1}:#{nonce}:#{cnonce}")
        else
          ha1
        end

      method_str = method |> to_string() |> String.upcase()
      ha2 = hash_func.("#{method_str}:#{uri}")

      response =
        if qop in ["auth", "auth-int"] do
          hash_func.("#{ha1}:#{nonce}:#{nc}:#{cnonce}:#{qop}:#{ha2}")
        else
          hash_func.("#{ha1}:#{nonce}:#{ha2}")
        end

      build_digest_auth_header(
        username: username,
        realm: realm,
        nonce: nonce,
        uri: uri,
        response: response,
        qop: qop,
        nc: nc,
        cnonce: cnonce,
        opaque: opaque,
        algorithm: algorithm
      )
    end
  end

  defp digest_md5_hash(data) do
    :md5
    |> :crypto.hash(data)
    |> Base.encode16(case: :lower)
  end

  defp digest_sha256_hash(data) do
    :sha256
    |> :crypto.hash(data)
    |> Base.encode16(case: :lower)
  end

  defp generate_digest_cnonce do
    16
    |> :crypto.strong_rand_bytes()
    |> Base.encode16(case: :lower)
  end

  defp digest_hash_function(algorithm) do
    case String.upcase(algorithm) do
      "MD5" -> {:ok, &digest_md5_hash/1, false}
      "MD5-SESS" -> {:ok, &digest_md5_hash/1, true}
      "SHA-256" -> {:ok, &digest_sha256_hash/1, false}
      "SHA-256-SESS" -> {:ok, &digest_sha256_hash/1, true}
      _ -> {:error, {:unsupported_digest_algorithm, algorithm}}
    end
  end

  defp build_digest_auth_header(opts) do
    opts =
      Keyword.validate!(opts, [
        :username,
        :realm,
        :nonce,
        :uri,
        :response,
        :nc,
        :cnonce,
        :algorithm,
        opaque: nil,
        qop: nil
      ])

    header_parts = Keyword.take(opts, [:username, :realm, :nonce, :uri, :response])

    qop_parts =
      if is_binary(opts[:qop]) do
        Keyword.take(opts, [:qop, :nc, :cnonce])
      end

    opaque_part =
      if is_binary(opts[:opaque]) do
        Keyword.take(opts, [:opaque])
      end

    algorithm_parts =
      if opts[:algorithm] |> String.upcase() |> String.ends_with?("-SESS") do
        Keyword.take(opts, [:algorithm, :cnonce])
      else
        Keyword.take(opts, [:algorithm])
      end

    header =
      header_parts
      |> Keyword.merge(qop_parts || [])
      |> Keyword.merge(opaque_part || [])
      |> Keyword.merge(algorithm_parts)
      |> Enum.map_join(", ", &encode_digest_header_part/1)

    {:ok, "Digest #{header}"}
  end

  defp encode_digest_header_part({key, value}) when key in [:algorithm, :qop, :nc] do
    "#{key}=#{value}"
  end

  defp encode_digest_header_part({key, value}) do
    "#{key}=#{quote_digest_value(value)}"
  end
end
