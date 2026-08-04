defmodule Req.ExpectTest do
  use Req.Case, async: true

  test "status integer" do
    %{req: req} =
      serve("GET /": &send_resp(&1, 200, "ok"))

    assert Req.stream!(req, expect: 200).body == "ok"

    {:error, err, resp} = Req.stream(req, expect: 201)
    assert Exception.message(err) =~ "expected response status 201, got: 200"
    assert resp.status == 200
  end

  test "status range" do
    %{req: req} =
      serve("GET /": &send_resp(&1, 200, "ok"))

    assert Req.stream!(req, expect: 200..201).body == "ok"

    {:error, err, resp} = Req.stream(req, expect: 201..202)
    assert Exception.message(err) =~ "expected response status 201..202, got: 200"
    assert resp.status == 200
  end

  test "status list" do
    %{req: req} =
      serve("GET /": &send_resp(&1, 200, "ok"))

    assert Req.stream!(req, expect: [200, 201]).body == "ok"

    {:error, err, _resp} = Req.stream(req, expect: [201, 202])
    assert Exception.message(err) =~ "expected response status [201, 202], got: 200"

    assert Req.stream!(req, expect: [200..201]).body == "ok"

    {:error, err, _resp} = Req.stream(req, expect: [201..202])
    assert Exception.message(err) =~ "expected response status [201..202], got: 200"
  end

  test "status category atom" do
    %{req: req, url: url} =
      serve(
        "GET /200": &send_resp(&1, 200, "ok"),
        "GET /301": &send_resp(&1, 301, "moved"),
        "GET /404": &send_resp(&1, 404, "not found"),
        "GET /500": &send_resp(&1, 500, "error")
      )

    assert Req.stream!(req, url: "#{url}/200", expect: :successful).body == "ok"

    {:error, err, _resp} = Req.stream(req, url: "#{url}/404", expect: :successful)
    assert Exception.message(err) =~ "expected response status :successful (200..299), got: 404"

    assert Req.stream!(req, url: "#{url}/301", expect: :redirection).body == "moved"

    {:error, err, _resp} = Req.stream(req, url: "#{url}/200", expect: :redirection)
    assert Exception.message(err) =~ "expected response status :redirection (300..399), got: 200"

    assert Req.stream!(req, url: "#{url}/404", expect: :client_error).body == "not found"

    assert Req.stream!(req, url: "#{url}/500", expect: :server_error, retry: false).body ==
             "error"
  end

  test "status category atom in list" do
    %{req: req} =
      serve("GET /": &send_resp(&1, 200, "ok"))

    assert Req.stream!(req, expect: [:successful, :redirection]).body == "ok"

    {:error, _err, _resp} = Req.stream(req, expect: [:redirection, :client_error])
  end
end
