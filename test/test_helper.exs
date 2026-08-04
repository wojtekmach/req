defmodule Req.Case do
  use ExUnit.CaseTemplate

  using do
    quote do
      import Req.Case
      import Plug.Conn
    end
  end

  def serve(plug_or_routes, options \\ [])

  def serve(plug, options) when is_function(plug, 1) do
    serve([*: plug], options)
  end

  def serve(routes, options) when is_list(routes) do
    plug = fn conn ->
      path = if conn.request_path in [nil, ""], do: "/", else: conn.request_path
      request = "#{conn.method} #{path}"

      case Enum.find(routes, fn {route, _} -> route == :* or Atom.to_string(route) == request end) do
        {_route, plug} -> Plug.run(conn, [plug])
        nil -> flunk("serve: no route matches #{request}")
      end
    end

    serve_plug(plug, options)
  end

  def serve_sequence(routes, options \\ []) when is_list(routes) do
    counter = :counters.new(1, [])

    plug = fn conn ->
      :counters.add(counter, 1, 1)
      n = :counters.get(counter, 1)

      if route = Enum.at(routes, n - 1) do
        dispatch(conn, route)
      else
        flunk("serve: unexpected request ##{n}, only #{length(routes)} route(s) expected")
      end
    end

    serve_plug(plug, options)
  end

  defp serve_plug(plug, options) do
    plugs = [{Plug.Parsers, parsers: [:multipart], pass: ["*/*"]}, plug]

    case adapter() do
      :plug ->
        url = URI.new!("http://localhost:8000")
        %{req: Req.new(url: url, plug: plug), url: url}

      :finch ->
        %{url: url} = start_http_server(plugs, options)
        %{req: Req.new(url: url), adapter: Req.Finch, url: url}

      :httpc ->
        %{url: url} = start_http_server(plugs, options)
        %{req: Req.new(url: url, adapter: Req.HTTPC), url: url}

      :mint ->
        %{url: url} = start_http_server(plugs, options)
        %{req: Req.new(url: url, adapter: Req.Mint), url: url}
    end
  end

  defp dispatch(conn, {route, plug}) do
    path = if conn.request_path in [nil, ""], do: "/", else: conn.request_path
    assert "#{conn.method} #{path}" == Atom.to_string(route)
    Plug.run(conn, [plug])
  end

  def start_http_server(plug_or_plugs, options \\ [])

  def start_http_server(plugs, options) when is_list(plugs) do
    start_http_server(&Plug.run(&1, plugs), options)
  end

  def start_http_server(plug, options) when is_function(plug, 1) do
    options =
      [
        scheme: :http,
        port: 0,
        plug: fn conn, _ -> plug.(conn) end,
        startup_log: false,
        http_options: [compress: false],
        thousand_island_options: [shutdown_timeout: 100]
      ] ++ options

    pid = ExUnit.Callbacks.start_supervised!({Bandit, options})
    {:ok, {ip, port}} = ThousandIsland.listener_info(pid)
    %{pid: pid, ip: ip, port: port, url: URI.new!("http://localhost:#{port}")}
  end

  def start_https_server(plug) when is_function(plug, 1) do
    options = [
      scheme: :https,
      port: 0,
      plug: fn conn, _ -> plug.(conn) end,
      startup_log: false,
      http_options: [compress: false],
      thousand_island_options: [shutdown_timeout: 100],
      certfile: "#{__DIR__}/support/cert.pem",
      keyfile: "#{__DIR__}/support/key.pem"
    ]

    pid = ExUnit.Callbacks.start_supervised!({Bandit, options})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    %{pid: pid, url: URI.new!("https://localhost:#{port}")}
  end

  def start_tcp_server(fun, options \\ []) do
    options =
      Keyword.validate!(options,
        before_accept: fn _listen_socket -> :ok end,
        listen_options: []
      )

    {:ok, listen_socket} =
      :gen_tcp.listen(0, [mode: :binary, active: false] ++ options[:listen_options])

    {:ok, port} = :inet.port(listen_socket)

    pid =
      ExUnit.Callbacks.start_supervised!(
        {Task,
         fn ->
           options[:before_accept].(listen_socket)
           accept(listen_socket, fun)
         end}
      )

    %{pid: pid, url: URI.new!("http://localhost:#{port}")}
  end

  defp accept(listen_socket, fun) do
    case :gen_tcp.accept(listen_socket) do
      {:ok, socket} ->
        fun.(socket)
        :ok = :gen_tcp.close(socket)

      {:error, :closed} ->
        :ok
    end

    accept(listen_socket, fun)
  end

  def adapter_fun do
    case adapter() do
      :finch ->
        Req.Finch

      :httpc ->
        Req.HTTPC

      :mint ->
        Req.Mint
    end
  end

  def adapter do
    case System.get_env("REQ_ADAPTER", "finch") do
      "finch" ->
        :finch

      "httpc" ->
        :httpc

      "mint" ->
        :mint

      "plug" ->
        :plug

      adapter ->
        raise "unknown REQ_ADAPTER=#{inspect(adapter)}"
    end
  end

  def create_tar(files, options \\ []) when is_list(files) do
    options = Keyword.validate!(options, compressed: false)
    compressed = Keyword.fetch!(options, :compressed)

    fun = fn
      :write, {pid, data} -> IO.write(pid, data)
      :position, {_pid, {:cur, 0}} -> {:ok, 0}
      :close, _pid -> :ok
    end

    {:ok, pid} = StringIO.open("")
    {:ok, tar} = :erl_tar.init(pid, :write, fun)

    for {path, content} <- files do
      :ok = :erl_tar.add(tar, content, to_charlist(path), [])
    end

    :ok = :erl_tar.close(tar)
    data = StringIO.flush(pid)
    if compressed, do: :zlib.gzip(data), else: data
  end

  def send_resp_chunked(conn, enumerable) do
    conn = Plug.Conn.send_chunked(conn, 200)

    Enum.reduce(enumerable, conn, fn chunk, conn ->
      {:ok, conn} = Plug.Conn.chunk(conn, chunk)
      conn
    end)
  end

  def send_resp_sse(conn, enumerable) do
    conn
    |> put_new_resp_header("content-type", "text/event-stream")
    |> send_resp_chunked(enumerable)
  end

  def send_resp_gzip(conn, body) when is_binary(body) do
    conn
    |> put_new_resp_header("content-encoding", "gzip")
    |> Plug.Conn.send_resp(200, :zlib.gzip(body))
  end

  def send_resp_br(conn, body) when is_binary(body) do
    {:ok, compressed} = :brotli.encode(body)

    conn
    |> put_new_resp_header("content-encoding", "br")
    |> Plug.Conn.send_resp(200, compressed)
  end

  def send_resp_zstd(conn, body) when is_binary(body) do
    conn
    |> put_new_resp_header("content-encoding", "zstd")
    |> Plug.Conn.send_resp(200, IO.iodata_to_binary(:zstd.compress(body)))
  end

  def send_resp_zip(conn, files) when is_list(files) do
    {:ok, {_name, zip}} = :zip.create(~c"a.zip", files, [:memory])

    conn
    |> put_new_resp_header("content-type", "application/zip")
    |> Plug.Conn.send_resp(200, zip)
  end

  def send_resp_tar(conn, files) when is_list(files) do
    fun = fn
      :write, {pid, data} -> IO.write(pid, data)
      :position, {_pid, {:cur, 0}} -> {:ok, 0}
      :close, _pid -> :ok
    end

    {:ok, pid} = StringIO.open("")
    {:ok, tar} = :erl_tar.init(pid, :write, fun)

    for {path, content} <- files do
      :ok = :erl_tar.add(tar, content, to_charlist(path), [])
    end

    :ok = :erl_tar.close(tar)

    conn
    |> put_new_resp_header("content-type", "application/x-tar")
    |> Plug.Conn.send_resp(200, StringIO.flush(pid))
  end

  def send_resp_csv(conn, rows) when is_list(rows) do
    conn
    |> put_new_resp_header("content-type", "text/csv")
    |> Plug.Conn.send_resp(200, NimbleCSV.RFC4180.dump_to_iodata(rows))
  end

  def send_resp_retry_after(conn, retry_after) do
    conn
    |> Plug.Conn.put_resp_header("retry-after", retry_after(retry_after))
    |> Plug.Conn.send_resp(conn.status || 429, "")
  end

  defp retry_after(integer) when is_integer(integer), do: to_string(integer)
  defp retry_after(%DateTime{} = dt), do: Req.Utils.format_http_date(dt)

  def send_redirect(conn, status, url) do
    conn
    |> Plug.Conn.put_resp_header("location", url)
    |> Plug.Conn.send_resp(status, "redirecting to #{url}")
  end

  defp put_new_resp_header(conn, name, value) do
    case Plug.Conn.get_resp_header(conn, name) do
      [] -> Plug.Conn.put_resp_header(conn, name, value)
      _ -> conn
    end
  end
end

exclude =
  case Req.Case.adapter() do
    :finch ->
      [:integration]

    :httpc ->
      [:integration]

    :mint ->
      [:integration]

    :plug ->
      [:integration, :transport, :adapter_finch, :adapter_httpc]
  end

if adapter = System.get_env("REQ_ADAPTER") do
  IO.puts("\nRunning with REQ_ADAPTER=#{adapter}\n")
end

ExUnit.configure(exclude: exclude)
ExUnit.start()
