defmodule Req.IntegrationTest do
  use ExUnit.Case, async: true

  @moduletag :integration

  setup context do
    if context[:doctest] do
      original_gl = Process.group_leader()
      {:ok, capture_gl} = StringIO.open("")
      Process.group_leader(self(), capture_gl)

      on_exit(fn ->
        Process.group_leader(self(), original_gl)
      end)
    else
      :ok
    end
  end

  doctest Req,
    only: [
      get!: 2,
      head!: 2,
      post!: 2,
      put!: 2,
      patch!: 2,
      delete!: 2,
      run: 2,
      run!: 2
    ]

  doctest Req.Steps,
    only: [
      auth: 1,
      checksum: 1,
      put_user_agent: 1,
      compressed: 1,
      put_base_url: 1,
      encode_body: 1,
      put_params: 1,
      put_path_params: 1,
      put_range: 1,
      cache: 1,
      decompress_body: 1,
      handle_http_errors: 1,
      expect: 1
    ]

  @tag :s3
  test "s3" do
    aws_access_key_id = System.fetch_env!("REQ_AWS_ACCESS_KEY_ID")
    aws_secret_access_key = System.fetch_env!("REQ_AWS_SECRET_ACCESS_KEY")
    aws_bucket = System.fetch_env!("REQ_AWS_BUCKET")

    req =
      Req.new(
        base_url: "https://#{aws_bucket}.s3.amazonaws.com",
        aws_sigv4: [
          access_key_id: aws_access_key_id,
          secret_access_key: aws_secret_access_key
        ]
      )

    now = to_string(DateTime.utc_now())

    %{status: 200} =
      Req.put!(req,
        url: "/key1",
        body: now
      )

    assert Req.get!(req, url: "/key1").body == now

    now = to_string(DateTime.utc_now())

    %{status: 200} =
      Req.put!(req,
        url: "/key1",
        headers: [content_length: byte_size(now) * 2],
        body: Stream.take(Stream.cycle([now]), 2)
      )

    assert Req.get!(req, url: "/key1").body == String.duplicate(now, 2)
  end
end
