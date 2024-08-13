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
    url = URI.parse(url)
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
    [] = options

    datetime = DateTime.truncate(datetime, :second)
    datetime_string = DateTime.to_iso8601(datetime, :basic)
    date_string = Date.to_iso8601(datetime, :basic)
    url = URI.parse(url)
    service = to_string(service)

    canonical_query_string =
      URI.encode_query([
        {"X-Amz-Algorithm", "AWS4-HMAC-SHA256"},
        {"X-Amz-Credential", "#{access_key_id}/#{date_string}/#{region}/#{service}/aws4_request"},
        {"X-Amz-Date", datetime_string},
        {"X-Amz-Expires", expires},
        {"X-Amz-SignedHeaders", "host"}
      ])

    canonical_headers = canonical_host_header([], url)

    signed_headers =
      Enum.map_intersperse(
        Enum.sort(canonical_headers),
        ";",
        &String.downcase(elem(&1, 0), :ascii)
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

    put_in(url.query, canonical_query_string <> "&X-Amz-Signature=#{signature}")
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

      iex> Req.Utils.format_http_datetime(~U[2024-01-01 09:00:00Z])
      "Mon, 01 Jan 2024 09:00:00 GMT"
  """
  def format_http_datetime(datetime) do
    Calendar.strftime(datetime, "%a, %d %b %Y %H:%M:%S GMT")
  end

  @doc """
  Returns a stream where each element is gzipped.

  ## Examples

      iex> gzipped = Req.Utils.stream_gzip(~w[foo bar baz]) |> Enum.to_list()
      iex> :zlib.gunzip(gzipped)
      "foobarbaz"
  """
  def stream_gzip(enumerable) do
    eof = make_ref()

    enumerable
    |> Stream.concat([eof])
    |> Stream.transform(
      fn ->
        z = :zlib.open()
        # https://github.com/erlang/otp/blob/OTP-26.0/erts/preloaded/src/zlib.erl#L551
        :ok = :zlib.deflateInit(z, :default, :deflated, 16 + 15, 8, :default)
        z
      end,
      fn
        ^eof, z ->
          buf = :zlib.deflate(z, [], :finish)
          {buf, z}

        data, z ->
          buf = :zlib.deflate(z, data)
          {buf, z}
      end,
      fn z ->
        :ok = :zlib.deflateEnd(z)
        :ok = :zlib.close(z)
      end
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

    footer = [[@crlf, "--", boundary, "--", @crlf]]

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

  defp add_form_parts({parts1, size1}, {parts2, size2})
       when is_list(parts1) and is_list(parts2) do
    {[parts1, parts2], size1 + size2}
  end

  defp add_form_parts({parts1, size1}, {parts2, size2}) do
    {Stream.concat(parts1, parts2), size1 + size2}
  end

  defp encode_form_part({name, {value, options}}, boundary) do
    options = Keyword.validate!(options, [:filename, :content_type])

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
    header = [[@crlf, "--", boundary, @crlf, headers, @crlf]]
    add_form_parts({header, IO.iodata_length(header)}, {parts, parts_size})
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
end
