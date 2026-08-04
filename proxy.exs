Mix.install([
  {:req, path: "."},
  :bandit
])

defmodule Proxy do
  def start_link(upstream_url: upstream_url) do
    with {:ok, pid} <- Bandit.start_link(port: 0, plug: {&forward/2, upstream_url}),
         {:ok, {_ip, port}} <- ThousandIsland.listener_info(pid) do
      {:ok, %{url: URI.new!("http://localhost:#{port}")}}
    end
  end

  defp forward(conn, upstream_url) do
    {:ok, _resp, conn} =
      Req.stream(
        upstream_url,
        conn,
        fn
          data, resp, %{state: :unset} = conn ->
            [content_type] = Req.Response.get_header(resp, "content-type")

            conn =
              conn
              |> Plug.Conn.put_resp_header("content-type", content_type)
              |> Plug.Conn.send_chunked(resp.status)

            {:ok, conn} = Plug.Conn.chunk(conn, data)
            {:cont, conn}

          data, _resp, %{state: :chunked} = conn ->
            {:ok, conn} = Plug.Conn.chunk(conn, data)
            {:cont, conn}
        end,
        method: conn.method,
        body: fn conn ->
          case Plug.Conn.read_body(conn) do
            {:ok, "", conn} ->
              {:done, conn}

            {:ok, data, conn} ->
              {:data, data, conn}

            {:more, data, conn} ->
              {:data, data, conn}
          end
        end,
        raw: true
      )

    conn
  end
end

{:ok, %{url: url}} = Proxy.start_link(upstream_url: "https://reqbin.org/inspect")

resp = Req.post!(url, body: "Hello, World!")
dbg(resp.body)
