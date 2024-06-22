defmodule Req.UtilsTest do
  use ExUnit.Case, async: true

  # TODO: Remove when we require Elixir 1.14
  if Version.match?(System.version(), "~> 1.14") do
    doctest Req.Utils
  end

  describe "aws_sigv4_headers" do
    test "GET" do
      options = [
        access_key_id: "dummy-access-key-id",
        secret_access_key: "dummy-secret-access-key",
        region: "dummy-region",
        service: "s3",
        datetime: ~U[2024-01-01 09:00:00Z],
        method: :get,
        url: "https://s3/test/path:v1/invoke",
        headers: [{"host", "s3"}],
        body: ""
      ]

      signature1 = Req.Utils.aws_sigv4_headers(options)

      signature2 =
        :aws_signature.sign_v4(
          Keyword.fetch!(options, :access_key_id),
          Keyword.fetch!(options, :secret_access_key),
          Keyword.fetch!(options, :region),
          Keyword.fetch!(options, :service),
          Keyword.fetch!(options, :datetime) |> NaiveDateTime.to_erl(),
          Keyword.fetch!(options, :method) |> Atom.to_string() |> String.upcase(),
          Keyword.fetch!(options, :url),
          Keyword.fetch!(options, :headers),
          Keyword.fetch!(options, :body),
          Keyword.take(options, [:body_digest])
        )

      assert signature1 ==
               Enum.map(signature2, fn {name, value} -> {String.downcase(name), value} end)
    end
  end

  describe "aws_sigv4_url" do
    test "GET" do
      options = [
        access_key_id: "dummy-access-key-id",
        secret_access_key: "dummy-secret-access-key",
        region: "dummy-region",
        service: "s3",
        datetime: ~U[2024-01-01 09:00:00Z],
        method: :get,
        url: "https://s3/test/path:v1/invoke"
      ]

      url1 = to_string(Req.Utils.aws_sigv4_url(options))

      url2 =
        """
        https://s3/test/path:v1/invoke?\
        X-Amz-Algorithm=AWS4-HMAC-SHA256\
        &X-Amz-Credential=dummy-access-key-id%2F20240101%2Fdummy-region%2Fs3%2Faws4_request\
        &X-Amz-Date=20240101T090000Z\
        &X-Amz-Expires=86400\
        &X-Amz-SignedHeaders=host\
        &X-Amz-Signature=ecf87c262f65848b65f7453bfb0f4f3327fecf8a6cb41bdae827b2df5702bd26\
        """

      assert url1 == url2
    end
  end
end
