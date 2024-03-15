defmodule Req.UtilsTest do
  use ExUnit.Case, async: true
  doctest Req.Utils

  describe "aws_sigv4" do
    test "GET" do
      options = [
        access_key_id: "dummy-access-key-id",
        secret_access_key: "dummy-secret-access-key",
        region: "dummy-region",
        service: "s3",
        datetime: ~U[2024-01-01 09:00:00Z],
        method: :get,
        url: "https://s3",
        headers: [{"host", "s3"}],
        body: ""
      ]

      signature1 = Req.Utils.aws_sigv4(options)

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
end
