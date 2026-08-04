defmodule HTTPBinTest do
  use Req.Case, async: true

  # TODO: Use JSON when we depend on Elixir 1.18.
  @json Jason

  setup do
    serve(*: {HTTPBin, []})
  end

  test "/json", %{req: req, url: url} do
    resp = Req.get!(req, url: "#{url}/json")
    assert resp.status == 200
    assert resp.body["slideshow"]["title"] == "Sample Slide Show"

    raw = Req.get!(req, url: "#{url}/json", decode_body: false).body
    sha1 = :crypto.hash(:sha, raw) |> Base.encode16(case: :lower)
    resp = Req.get!(req, url: "#{url}/json", checksum: "sha1:#{sha1}")
    assert resp.status == 200
  end

  test "/user-agent", %{req: req, url: url} do
    resp = Req.get!(req, url: "#{url}/user-agent", user_agent: "foo")
    assert resp.status == 200
    assert resp.body == %{"user-agent" => "foo"}
  end

  test "/anything echoes args/data/form/json/method", %{req: req, url: url} do
    resp = Req.get!(req, url: "#{url}/anything/query", params: [x: 1, y: 2])
    assert resp.status == 200
    assert resp.body["args"] == %{"x" => "1", "y" => "2"}

    resp = Req.post!(req, url: "#{url}/anything", body: "hello!")
    assert resp.status == 200
    assert resp.body["data"] == "hello!"
    resp = Req.post!(req, url: "#{url}/anything", form: [x: 1])
    assert resp.status == 200
    assert resp.body["form"] == %{"x" => "1"}
    resp = Req.post!(req, url: "#{url}/anything", json: %{x: 2})
    assert resp.status == 200
    assert resp.body["json"] == %{"x" => 2}
    resp = Req.delete!(req, url: "#{url}/anything")
    assert resp.status == 200
    assert resp.body["method"] == "DELETE"
  end

  test "/post", %{req: req, url: url} do
    resp = Req.post!(req, url: "#{url}/post", form: [comments: "hello!"])
    assert resp.status == 200
    assert resp.body["form"] == %{"comments" => "hello!"}

    resp = Req.post!(req, url: "#{url}/post", json: %{a: 1})
    assert resp.status == 200
    assert resp.body["json"] == %{"a" => 1}
  end

  test "/post streaming body", %{req: req, url: url} do
    stream = Stream.duplicate("foo", 3)
    resp = Req.post!(req, url: "#{url}/post", body: stream)
    assert resp.status == 200
    assert resp.body["data"] == "foofoofoo"
  end

  test "/anything multipart", %{req: req, url: url} do
    fields = [a: 1, b: {"2", filename: "b.txt"}]
    resp = Req.post!(req, url: "#{url}/anything", form_multipart: fields)
    assert resp.body["form"] == %{"a" => "1"}
    assert resp.body["files"] == %{"b" => "2"}
  end

  test "/anything multipart streaming", %{req: req, url: url} do
    stream = Stream.cycle(["abc"]) |> Stream.take(3)

    resp =
      Req.post!(req,
        url: "#{url}/anything",
        form_multipart: [file: {stream, filename: "b.txt"}]
      )

    assert resp.body["files"] == %{"file" => "abcabcabc"}
  end

  test "/status", %{req: req, url: url} do
    resp = Req.get!(req, url: "#{url}/status/:code", path_params: [code: 201])
    assert resp.status == 201
    resp = Req.head!(req, url: "#{url}/status/201")
    assert resp.status == 201
    resp = Req.get!(req, url: "#{url}/status/404", retry: false)
    assert resp.status == 404
  end

  test "/basic-auth", %{req: req, url: url} do
    resp = Req.get!(req, url: "#{url}/basic-auth/foo/bar", auth: {:basic, "foo:foo"})
    assert resp.status == 401

    resp = Req.get!(req, url: "#{url}/basic-auth/foo/bar", auth: {:basic, "foo:bar"})
    assert resp.status == 200
  end

  test "/bearer", %{req: req, url: url} do
    resp = Req.get!(req, url: "#{url}/bearer")
    assert resp.status == 401
    resp = Req.get!(req, url: "#{url}/bearer", auth: {:bearer, "foo"})
    assert resp.status == 200
  end

  test "/digest-auth", %{req: req, url: url} do
    resp = Req.get!(req, url: "#{url}/digest-auth/auth/user/pass", auth: {:digest, "user:pass"})
    assert resp.status == 200
  end

  test "/range", %{req: req, url: url} do
    resp = Req.get!(req, url: "#{url}/range/100", range: 0..3)
    assert resp.status == 206
    assert resp.body == "abcd"
    assert Req.Response.get_header(resp, "content-range") == ["bytes 0-3/100"]
  end

  test "/stream", %{req: req, url: url} do
    lines =
      Req.get!(req, url: "#{url}/stream/2", decode_body: false).body
      |> String.split("\n", trim: true)
      |> Enum.map(&@json.decode!/1)

    assert Enum.map(lines, & &1["id"]) == [0, 1]
  end

  test "/gzip", %{req: req, url: url} do
    resp = Req.get!(req, url: "#{url}/gzip", compressed: true)
    assert resp.status == 200
    assert resp.body["gzipped"] == true
  end

  @tag :capture_log
  test "/redirect", %{req: req, url: url} do
    resp = Req.get!(req, url: "#{url}/redirect/2")
    assert resp.status == 200
  end
end
