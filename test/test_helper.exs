defmodule TestHelper do
  def start_http_server(plug) do
    options = [
      scheme: :http,
      port: 0,
      plug: fn conn, _ -> plug.(conn) end,
      startup_log: false,
      http_options: [compress: false]
    ]

    pid = ExUnit.Callbacks.start_supervised!({Bandit, options})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    %{pid: pid, url: URI.new!("http://localhost:#{port}")}
  end

  def start_tcp_server(fun) do
    {:ok, listen_socket} = :gen_tcp.listen(0, mode: :binary, active: false)
    {:ok, port} = :inet.port(listen_socket)
    pid = ExUnit.Callbacks.start_supervised!({Task, fn -> accept(listen_socket, fun) end})
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
end

defmodule EzstdFilter do
  # Filter out:
  # 17:56:39.116 [debug] Loading library: ~c"/path/to/req/_build/test/lib/ezstd/priv/ezstd_nif"
  def filter(log_event, _opts) do
    case log_event.msg do
      {"Loading library" <> _, [path]} ->
        ^path = to_charlist(Application.app_dir(:ezstd, "priv/ezstd_nif"))
        :stop

      _ ->
        :ignore
    end
  end
end

:logger.add_primary_filter(:ezstd_filter, {&EzstdFilter.filter/2, []})

ExUnit.configure(exclude: :integration)
ExUnit.start()
