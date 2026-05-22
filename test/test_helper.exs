defmodule Req.Case do
  use ExUnit.CaseTemplate

  using do
    quote do
      import Req.Case
    end
  end

  def start_http_server(plug, options \\ []) when is_function(plug, 1) do
    options =
      [
        scheme: :http,
        port: 0,
        plug: fn conn, _ -> plug.(conn) end,
        startup_log: false,
        http_options: [compress: false]
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
      certfile: "#{__DIR__}/support/cert.pem",
      keyfile: "#{__DIR__}/support/key.pem"
    ]

    pid = ExUnit.Callbacks.start_supervised!({Bandit, options})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    %{pid: pid, url: URI.new!("https://localhost:#{port}")}
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

  def adapter do
    case System.get_env("REQ_ADAPTER", "finch") do
      "finch" ->
        :finch

      "httpc" ->
        :httpc

      adapter ->
        raise "unknown REQ_ADAPTER=#{inspect(adapter)}"
    end
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

exclude =
  if Req.Case.adapter() == :httpc do
    [:integration, :http2]
  else
    [:integration]
  end

if adapter = System.get_env("REQ_ADAPTER") do
  IO.puts("Running with REQ_ADAPTER=#{adapter}")
end

ExUnit.configure(exclude: exclude)
ExUnit.start()
