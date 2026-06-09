defmodule HTTPBinTest do
  use Req.Case, async: true

  setup do
    %{url: url} = start_http_server(fn conn -> HTTPBin.call(conn, []) end)
    [base: to_string(url)]
  end

  test "/json", %{base: base} do
    resp = Req.get!(base <> "/json")
    assert resp.status == 200
    assert resp.body["slideshow"]["title"] == "Sample Slide Show"

    raw = Req.get!(base <> "/json", decode_body: false).body
    sha1 = :crypto.hash(:sha, raw) |> Base.encode16(case: :lower)
    assert Req.get!(base <> "/json", checksum: "sha1:#{sha1}").status == 200
  end

  test "/user-agent", %{base: base} do
    assert Req.get!(base <> "/user-agent", user_agent: "foo").body == %{"user-agent" => "foo"}
  end

  test "/anything echoes args/data/form/json/method", %{base: base} do
    assert Req.get!(base <> "/anything/query", params: [x: 1, y: 2]).body["args"] ==
             %{"x" => "1", "y" => "2"}

    assert Req.post!(base <> "/anything", body: "hello!").body["data"] == "hello!"
    assert Req.post!(base <> "/anything", form: [x: 1]).body["form"] == %{"x" => "1"}
    assert Req.post!(base <> "/anything", json: %{x: 2}).body["json"] == %{"x" => 2}
    assert Req.delete!(base <> "/anything").body["method"] == "DELETE"
  end

  test "/post", %{base: base} do
    assert Req.post!(base <> "/post", form: [comments: "hello!"]).body["form"] ==
             %{"comments" => "hello!"}

    assert Req.post!(base <> "/post", json: %{a: 1}).body["json"] == %{"a" => 1}

    stream = Stream.duplicate("foo", 3)
    assert Req.post!(base <> "/post", body: stream).body["data"] == "foofoofoo"
  end

  test "/anything multipart", %{base: base} do
    fields = [a: 1, b: {"2", filename: "b.txt"}]
    resp = Req.post!(base <> "/anything", form_multipart: fields)
    assert resp.body["form"] == %{"a" => "1"}
    assert resp.body["files"] == %{"b" => "2"}

    stream = Stream.cycle(["abc"]) |> Stream.take(3)
    resp = Req.post!(base <> "/anything", form_multipart: [file: {stream, filename: "b.txt"}])
    assert resp.body["files"] == %{"file" => "abcabcabc"}
  end

  test "/status", %{base: base} do
    assert Req.get!(base <> "/status/:code", path_params: [code: 201]).status == 201
    assert Req.head!(base <> "/status/201").status == 201
    assert Req.get!(base <> "/status/404", retry: false).status == 404
  end

  test "/basic-auth", %{base: base} do
    assert Req.get!(base <> "/basic-auth/foo/bar", auth: {:basic, "foo:foo"}).status == 401
    assert Req.get!(base <> "/basic-auth/foo/bar", auth: {:basic, "foo:bar"}).status == 200
  end

  test "/bearer", %{base: base} do
    assert Req.get!(base <> "/bearer").status == 401
    assert Req.get!(base <> "/bearer", auth: {:bearer, "foo"}).status == 200
  end

  test "/digest-auth", %{base: base} do
    assert Req.get!(base <> "/digest-auth/auth/user/pass", auth: {:digest, "user:pass"}).status ==
             200
  end

  test "/range", %{base: base} do
    resp = Req.get!(base <> "/range/100", range: 0..3)
    assert resp.status == 206
    assert resp.body == "abcd"
    assert Req.Response.get_header(resp, "content-range") == ["bytes 0-3/100"]
  end

  test "/stream", %{base: base} do
    lines =
      Req.get!(base <> "/stream/2", decode_body: false).body
      |> String.split("\n", trim: true)
      |> Enum.map(&JSON.decode!/1)

    assert Enum.map(lines, & &1["id"]) == [0, 1]
  end

  test "/gzip", %{base: base} do
    assert Req.get!(base <> "/gzip", compressed: true).body["gzipped"] == true
  end

  test "/redirect", %{base: base} do
    assert Req.get!(base <> "/redirect/2").status == 200
  end
end
