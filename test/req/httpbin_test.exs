defmodule HTTPBinTest do
  use Req.Case, async: true

  @adapter Req.Case.adapter()

  setup do
    serve(fn conn -> HTTPBin.call(conn, []) end)
  end

  test "/json", %{req: req, url: url} do
    resp = Req.get!(req, url: "#{url}/json")
    assert resp.status == 200
    assert resp.body["slideshow"]["title"] == "Sample Slide Show"

    raw = Req.get!(req, url: "#{url}/json", decode_body: false).body
    sha1 = :crypto.hash(:sha, raw) |> Base.encode16(case: :lower)
    assert Req.get!(req, url: "#{url}/json", checksum: "sha1:#{sha1}").status == 200
  end

  test "/user-agent", %{req: req, url: url} do
    assert Req.get!(req, url: "#{url}/user-agent", user_agent: "foo").body ==
             %{"user-agent" => "foo"}
  end

  test "/anything echoes args/data/form/json/method", %{req: req, url: url} do
    assert Req.get!(req, url: "#{url}/anything/query", params: [x: 1, y: 2]).body["args"] ==
             %{"x" => "1", "y" => "2"}

    assert Req.post!(req, url: "#{url}/anything", body: "hello!").body["data"] == "hello!"
    assert Req.post!(req, url: "#{url}/anything", form: [x: 1]).body["form"] == %{"x" => "1"}
    assert Req.post!(req, url: "#{url}/anything", json: %{x: 2}).body["json"] == %{"x" => 2}
    assert Req.delete!(req, url: "#{url}/anything").body["method"] == "DELETE"
  end

  test "/post", %{req: req, url: url} do
    assert Req.post!(req, url: "#{url}/post", form: [comments: "hello!"]).body["form"] ==
             %{"comments" => "hello!"}

    assert Req.post!(req, url: "#{url}/post", json: %{a: 1}).body["json"] == %{"a" => 1}
  end

  # TODO: implement enumerable request body in Req.HTTPC adapter
  @tag skip: @adapter == :httpc
  test "/post streaming body", %{req: req, url: url} do
    stream = Stream.duplicate("foo", 3)
    assert Req.post!(req, url: "#{url}/post", body: stream).body["data"] == "foofoofoo"
  end

  test "/anything multipart", %{req: req, url: url} do
    fields = [a: 1, b: {"2", filename: "b.txt"}]
    resp = Req.post!(req, url: "#{url}/anything", form_multipart: fields)
    assert resp.body["form"] == %{"a" => "1"}
    assert resp.body["files"] == %{"b" => "2"}
  end

  # TODO: implement enumerable request body in Req.HTTPC adapter
  @tag skip: @adapter == :httpc
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
    assert Req.get!(req, url: "#{url}/status/:code", path_params: [code: 201]).status == 201
    assert Req.head!(req, url: "#{url}/status/201").status == 201
    assert Req.get!(req, url: "#{url}/status/404", retry: false).status == 404
  end

  test "/basic-auth", %{req: req, url: url} do
    assert Req.get!(req, url: "#{url}/basic-auth/foo/bar", auth: {:basic, "foo:foo"}).status ==
             401

    assert Req.get!(req, url: "#{url}/basic-auth/foo/bar", auth: {:basic, "foo:bar"}).status ==
             200
  end

  test "/bearer", %{req: req, url: url} do
    assert Req.get!(req, url: "#{url}/bearer").status == 401
    assert Req.get!(req, url: "#{url}/bearer", auth: {:bearer, "foo"}).status == 200
  end

  test "/digest-auth", %{req: req, url: url} do
    assert Req.get!(req, url: "#{url}/digest-auth/auth/user/pass", auth: {:digest, "user:pass"}).status ==
             200
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
      |> Enum.map(&JSON.decode!/1)

    assert Enum.map(lines, & &1["id"]) == [0, 1]
  end

  test "/gzip", %{req: req, url: url} do
    assert Req.get!(req, url: "#{url}/gzip", compressed: true).body["gzipped"] == true
  end

  @tag :capture_log
  test "/redirect", %{req: req, url: url} do
    assert Req.get!(req, url: "#{url}/redirect/2").status == 200
  end
end
