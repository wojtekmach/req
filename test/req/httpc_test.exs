# Experimental httpc adapter to test the adapter contract.

defmodule Req.HttpcTest do
  use ExUnit.Case, async: true

  require Logger

  setup do
    bypass = Bypass.open()

    req =
      Req.new(
        adapter: &run_httpc/1,
        url: "http://localhost:#{bypass.port}"
      )

    [bypass: bypass, req: req]
  end

  if function_exported?(Mix, :ensure_application!, 1) do
    Mix.ensure_application!(:inets)
  end

  describe "run_httpc/1" do
    test "request", %{bypass: bypass, req: req} do
      Bypass.expect(bypass, "GET", "/", fn conn ->
        Plug.Conn.send_resp(conn, 200, "ok")
      end)

      resp = Req.get!(req)
      assert resp.status == 200
      assert Req.Response.get_header(resp, "server") == ["Cowboy"]
      assert resp.body == "ok"
    end

    test "post request body", %{bypass: bypass, req: req} do
      Bypass.expect(bypass, "POST", "/", fn conn ->
        assert {:ok, body, conn} = Plug.Conn.read_body(conn)
        Plug.Conn.send_resp(conn, 200, body)
      end)

      resp = Req.post!(req, body: "foofoofoo")
      assert resp.status == 200
      assert resp.body == "foofoofoo"
    end

    test "stream request body", %{bypass: bypass, req: req} do
      Bypass.expect(bypass, "POST", "/", fn conn ->
        assert {:ok, body, conn} = Plug.Conn.read_body(conn)
        Plug.Conn.send_resp(conn, 200, body)
      end)

      resp = Req.post!(req, body: {:stream, Stream.take(["foo", "foo", "foo"], 2)})
      assert resp.status == 200
      assert resp.body == "foofoo"
    end

    test "into: fun", %{req: req, bypass: bypass} do
      Bypass.expect(bypass, "GET", "/", fn conn ->
        conn = Plug.Conn.send_chunked(conn, 200)
        {:ok, conn} = Plug.Conn.chunk(conn, "foo")
        {:ok, conn} = Plug.Conn.chunk(conn, "bar")
        conn
      end)

      pid = self()

      resp =
        Req.get!(
          req,
          into: fn {:data, data}, acc ->
            send(pid, {:data, data})
            {:cont, acc}
          end
        )

      assert resp.status == 200
      assert resp.headers["transfer-encoding"] == ["chunked"]
      assert_receive {:data, "foobar"}

      # httpc seems to randomly chunk things
      receive do
        {:data, ""} -> :ok
      after
        0 -> :ok
      end

      refute_receive _
    end

    test "into: :self", %{req: req, bypass: bypass} do
      Bypass.expect(bypass, "GET", "/", fn conn ->
        conn = Plug.Conn.send_chunked(conn, 200)
        {:ok, conn} = Plug.Conn.chunk(conn, "foo")
        {:ok, conn} = Plug.Conn.chunk(conn, "bar")
        conn
      end)

      resp = Req.get!(req, into: :self)
      assert resp.status == 200

      # httpc seems to randomly chunk things
      assert Req.parse_message(resp, assert_receive(_)) in [
               {:ok, [data: "foo"]},
               {:ok, [data: "foobar"]}
             ]

      assert Req.parse_message(resp, assert_receive(_)) in [
               {:ok, [data: "bar"]},
               {:ok, [data: ""]},
               {:ok, [:done]}
             ]
    end

    test "into: pid cancel", %{req: req, bypass: bypass} do
      Bypass.expect(bypass, "GET", "/", fn conn ->
        conn = Plug.Conn.send_chunked(conn, 200)
        {:ok, conn} = Plug.Conn.chunk(conn, "foo")
        {:ok, conn} = Plug.Conn.chunk(conn, "bar")
        conn
      end)

      resp = Req.get!(req, into: :self)
      assert resp.status == 200
      assert :ok = Req.cancel_async_response(resp)
    end
  end

  def run_httpc(request) do
    httpc_url = request.url |> URI.to_string() |> String.to_charlist()

    httpc_headers =
      for {name, values} <- request.headers,
          # TODO: remove List.wrap on Req 1.0
          value <- List.wrap(values) do
        {String.to_charlist(name), String.to_charlist(value)}
      end

    httpc_req =
      if request.method in [:post, :put] do
        content_type =
          case Req.Request.get_header(request, "content-type") do
            [value] ->
              String.to_charlist(value)

            [] ->
              ~c"application/octet-stream"
          end

        body =
          case request.body do
            {:stream, enumerable} ->
              httpc_enumerable_to_fun(enumerable)

            iodata ->
              iodata
          end

        {httpc_url, httpc_headers, content_type, body}
      else
        {httpc_url, httpc_headers}
      end

    httpc_http_options = [
      ssl: [
        verify: :verify_peer,
        cacertfile: CAStore.file_path(),
        depth: 2,
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ]
      ]
    ]

    httpc_options = [
      body_format: :binary
    ]

    case request.into do
      nil ->
        httpc_request(request, httpc_req, httpc_http_options, httpc_options)

      :self ->
        httpc_async(request, httpc_req, httpc_http_options, httpc_options, :self)

      fun ->
        httpc_async(request, httpc_req, httpc_http_options, httpc_options, fun)
    end
  end

  defp httpc_request(request, httpc_req, httpc_http_options, httpc_options) do
    case :httpc.request(request.method, httpc_req, httpc_http_options, httpc_options) do
      {:ok, {{_, status, _}, headers, body}} ->
        headers =
          for {name, value} <- headers do
            {List.to_string(name), List.to_string(value)}
          end

        {request, Req.Response.new(status: status, headers: headers, body: body)}
    end
  end

  defp httpc_enumerable_to_fun(enumerable) do
    reducer = fn item, _acc ->
      {:suspend, item}
    end

    {_, _, fun} = Enumerable.reduce(enumerable, {:suspend, nil}, reducer)

    {:chunkify, &httpc_next/1, fun}
  end

  defp httpc_next(fun) do
    case fun.({:cont, nil}) do
      {:suspended, element, fun} ->
        {:ok, element, fun}

      {:done, nil} ->
        :eof

      {:halted, element} ->
        {:ok, element, fn _ -> {:done, nil} end}
    end
  end

  defp httpc_async(request, httpc_req, httpc_http_options, httpc_options, self_or_fun) do
    stream =
      case self_or_fun do
        :self ->
          :self

        fun when is_function(fun) ->
          {:self, :once}
      end

    httpc_options = [sync: false, stream: stream] ++ httpc_options
    {:ok, ref} = :httpc.request(request.method, httpc_req, httpc_http_options, httpc_options)

    receive do
      {:http, {^ref, :stream_start, headers}} ->
        headers =
          for {name, value} <- headers do
            {List.to_string(name), List.to_string(value)}
          end

        status =
          case List.keyfind(headers, "content-range", 0) do
            {_, _} -> 206
            _ -> 200
          end

        async = %Req.Async{
          ref: ref,
          stream_fun: &httpc_stream/2,
          cancel_fun: &httpc_cancel/1
        }

        response = Req.Response.new(status: status, headers: headers)
        response = put_in(response.async, async)
        {request, response}

      {:http, {ref, :stream_start, headers, pid}} ->
        headers =
          for {name, value} <- headers do
            {List.to_string(name), List.to_string(value)}
          end

        status =
          case List.keyfind(headers, "content-range", 0) do
            {_, _} -> 206
            _ -> 200
          end

        response = Req.Response.new(status: status, headers: headers)

        case self_or_fun do
          :self ->
            {request, response}

          fun when is_function(fun) ->
            httpc_loop(request, response, ref, pid, fun)
        end

      {:http, {^ref, {{_, status, _}, headers, body}}} ->
        headers =
          for {name, value} <- headers do
            {List.to_string(name), List.to_string(value)}
          end

        response = Req.Response.new(status: status, headers: headers, body: body)
        {request, response}
    end
  end

  @doc false
  def httpc_stream(ref, {:http, {ref, :stream, data}}) do
    {:ok, [{:data, data}]}
  end

  # TODO: handle trailers
  def httpc_stream(ref, {:http, {ref, :stream_end, _headers}}) do
    {:ok, [:done]}
  end

  @doc false
  def httpc_cancel(ref) do
    :httpc.cancel_request(ref)
  end

  defp httpc_loop(request, response, ref, pid, fun) do
    :ok = :httpc.stream_next(pid)

    receive do
      {:http, {^ref, :stream, data}} ->
        case fun.({:data, data}, {request, response}) do
          {:cont, {request, response}} ->
            httpc_loop(request, response, ref, pid, fun)

          {:halt, {request, response}} ->
            :ok = :httpc.cancel_request(ref)
            {request, response}
        end

      # TODO: handle trailers
      {:http, {^ref, :stream_end, _headers}} ->
        {request, response}
    end
  end
end
