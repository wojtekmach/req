defmodule TestServer do
  def serve(fun) do
    {:ok, listen_socket} = :gen_tcp.listen(0, mode: :binary, active: false)
    {:ok, port} = :inet.port(listen_socket)
    pid = ExUnit.Callbacks.start_supervised!({Task, fn -> accept(listen_socket, fun) end})
    %{pid: pid, url: "http://localhost:#{port}"}
  end

  defp accept(listen_socket, fun) do
    {:ok, socket} = :gen_tcp.accept(listen_socket)
    fun.(socket)
    :ok = :gen_tcp.close(socket)
    accept(listen_socket, fun)
  end
end

ExUnit.configure(exclude: :integration)
ExUnit.start()
