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
  def aws_sigv4(options) do
    {access_key_id, options} = Keyword.pop!(options, :access_key_id)
    {secret_access_key, options} = Keyword.pop!(options, :secret_access_key)
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
    method = method |> Atom.to_string() |> String.upcase()
    url = URI.parse(url)
    body_digest = options[:body_digest] || hex(sha256(body))
    service = to_string(service)

    canonical_headers =
      headers ++
        [
          {"x-amz-content-sha256", body_digest},
          {"x-amz-date", datetime_string}
        ]

    signed_headers =
      Enum.map_intersperse(
        Enum.sort(canonical_headers),
        ";",
        &String.downcase(elem(&1, 0), :ascii)
      )

    canonical_request =
      iodata("""
      #{String.upcase(method)}
      #{url.path || "/"}
      #{url.query || ""}
      #{Enum.map_intersperse(canonical_headers, "\n", fn {name, value} -> [name, ":", value] end)}

      #{signed_headers}
      #{body_digest}\
      """)

    string_to_sign =
      iodata("""
      AWS4-HMAC-SHA256
      #{datetime_string}
      #{date_string}/#{region}/#{service}/aws4_request
      #{hex(sha256(canonical_request))}\
      """)

    signature =
      ["AWS4", secret_access_key]
      |> hmac(date_string)
      |> hmac(region)
      |> hmac(service)
      |> hmac("aws4_request")
      |> hmac(string_to_sign)
      |> hex()

    authorization =
      "AWS4-HMAC-SHA256 Credential=#{access_key_id}/#{date_string}/#{region}/#{service}/aws4_request,SignedHeaders=#{signed_headers},Signature=#{signature}"

    [
      {"authorization", authorization},
      {"x-amz-content-sha256", body_digest},
      {"x-amz-date", datetime_string}
    ] ++ headers
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
end
