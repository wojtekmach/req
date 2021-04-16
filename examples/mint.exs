defmodule Main do
  def main() do
    IO.inspect(get!("https://api.github.com/repos/elixir-lang/elixir").body["description"])
    # Outputs: "Elixir is a dynamic, functional language..."
  end

  defp get!(url) do
    Req.build(:get, url)
    |> Req.add_default_steps()
    |> Req.add_request_steps([
      &mint/1
    ])
    |> Req.run!()
  end

  defp mint(request) do
    scheme =
      case request.uri.scheme do
        "https" -> :https
        "http" -> :http
      end

    {:ok, conn} = Mint.HTTP.connect(scheme, request.uri.host, request.uri.port)

    {:ok, conn, request_ref} =
      Mint.HTTP.request(conn, "GET", request.uri.path, request.headers, request.body)

    response = mint_recv(conn, request_ref, %{})
    {request, response}
  end

  defp mint_recv(conn, request_ref, acc) do
    receive do
      message ->
        {:ok, conn, responses} = Mint.HTTP.stream(conn, message)
        acc = Enum.reduce(responses, acc, &mint_process(&1, request_ref, &2))

        if acc[:done] do
          Map.delete(acc, :done)
        else
          mint_recv(conn, request_ref, acc)
        end
    end
  end

  defp mint_process({:status, request_ref, status}, request_ref, response),
    do: put_in(response[:status], status)

  defp mint_process({:headers, request_ref, headers}, request_ref, response),
    do: put_in(response[:headers], headers)

  defp mint_process({:data, request_ref, new_data}, request_ref, response),
    do: update_in(response[:body], fn data -> (data || "") <> new_data end)

  defp mint_process({:done, request_ref}, request_ref, response),
    do: put_in(response[:done], true)
end

Main.main()
