# Finch proxy environment-variable tests. These mutate process env, so the whole
# module runs with async: false (ExUnit reserves :async at module level, not per test).
defmodule Req.FinchProxyEnvTest do
  use Req.Case, async: false

  @moduletag :adapter_finch

  describe "proxy env vars" do
    test "http_proxy env var" do
      %{url: url} =
        start_http_server(fn conn ->
          Plug.Conn.send_resp(conn, 200, "ok")
        end)

      previous = System.get_env("http_proxy")
      System.put_env("http_proxy", "http://localhost:#{url.port}")
      on_exit(fn -> restore_env("http_proxy", previous) end)

      resp = Req.stream!(base_url: url)
      assert resp.status == 200
      assert resp.body == "ok"
    end

    test "http_proxy env var with credentials" do
      %{url: url} =
        start_http_server(fn conn ->
          assert ["Basic " <> credentials] = Plug.Conn.get_req_header(conn, "proxy-authorization")
          assert Base.decode64!(credentials) == "user:pass"
          Plug.Conn.send_resp(conn, 200, "ok")
        end)

      previous = System.get_env("http_proxy")
      System.put_env("http_proxy", "http://user:pass@localhost:#{url.port}")
      on_exit(fn -> restore_env("http_proxy", previous) end)

      resp = Req.stream!(base_url: url)
      assert resp.status == 200
      assert resp.body == "ok"
    end

    test ":http_proxy option takes precedence over env var" do
      %{url: url} =
        start_http_server(fn conn ->
          Plug.Conn.send_resp(conn, 200, "ok")
        end)

      previous = System.get_env("http_proxy")
      System.put_env("http_proxy", "http://localhost:1")
      on_exit(fn -> restore_env("http_proxy", previous) end)

      req = Req.new(base_url: url, http_proxy: "http://localhost:#{url.port}")
      resp = Req.stream!(req)
      assert resp.status == 200
      assert resp.body == "ok"
    end

    test ":http_proxy false disables the env var fallback" do
      %{url: url} =
        start_http_server(fn conn ->
          Plug.Conn.send_resp(conn, 200, "ok")
        end)

      previous = System.get_env("http_proxy")
      System.put_env("http_proxy", "http://localhost:1")
      on_exit(fn -> restore_env("http_proxy", previous) end)

      req = Req.new(base_url: url, http_proxy: false)
      resp = Req.stream!(req)
      assert resp.status == 200
      assert resp.body == "ok"
    end

    test "http_proxy env var is ignored when :connect_options :proxy is set" do
      %{url: url} =
        start_http_server(fn conn ->
          Plug.Conn.send_resp(conn, 200, "ok")
        end)

      previous = System.get_env("http_proxy")
      System.put_env("http_proxy", "http://localhost:1")
      on_exit(fn -> restore_env("http_proxy", previous) end)

      req = Req.new(base_url: url, connect_options: [proxy: {:http, "localhost", url.port, []}])
      resp = Req.stream!(req)
      assert resp.status == 200
      assert resp.body == "ok"
    end

    test "http_proxy env var is ignored when a :finch pool is given" do
      previous = System.get_env("http_proxy")
      System.put_env("http_proxy", "http://localhost:1")
      on_exit(fn -> restore_env("http_proxy", previous) end)

      assert_raise ArgumentError, "unknown registry: MyFinch", fn ->
        Req.stream!("http://localhost", finch: [name: MyFinch])
      end
    end

    test "http_proxy unreachable proxy fails the request" do
      %{url: url} =
        start_http_server(fn conn ->
          Plug.Conn.send_resp(conn, 200, "ok")
        end)

      previous = System.get_env("http_proxy")
      System.put_env("http_proxy", "http://localhost:1")
      on_exit(fn -> restore_env("http_proxy", previous) end)

      assert {:error, %Req.TransportError{}} = Req.get(base_url: url, retry: false)
    end
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
