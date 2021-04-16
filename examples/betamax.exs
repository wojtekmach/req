defmodule Main do
  def main() do
    tape = "tmp/tape.bin"

    Betamax.with_betamax(tape, fn fun ->
      get!("https://hex.pm/api/packages/finch", fun)
      get!("https://hex.pm/api/packages/mint", fun)
      get!("https://hex.pm/api/packages/nimble_pool", fun)
    end)

    Betamax.with_betamax(tape, fn fun ->
      IO.inspect(get!("http://does-not-matter", fun).body["name"])
      # Outputs: finch

      IO.inspect(get!("http://does-not-matter", fun).body["name"])
      # Outputs: mint

      IO.inspect(get!("http://does-not-matter", fun).body["name"])
      # Outputs: nimble_pool
    end)
  end

  def get!(url, fun) do
    Req.build(:get, url)
    |> Req.add_default_steps()
    |> fun.()
    |> Req.run!()
  end
end

defmodule Betamax do
  def with_betamax(tape_path, fun) do
    case File.read(tape_path) do
      {:ok, contents} ->
        items = :erlang.binary_to_term(contents)
        {:ok, tape} = Betamax.Tape.start_link(items)

        fun.(fn request ->
          Req.add_request_steps(request, [&betamax_playback(&1, tape)])
        end)

      {:error, :enoent} ->
        {:ok, tape} = Betamax.Tape.start_link([])

        result =
          fun.(fn request ->
            prepend_response_steps(request, [&betamax_record(&1, &2, tape)])
          end)

        items = tape |> Betamax.Tape.items() |> Enum.reverse()
        File.write!(tape_path, :erlang.term_to_binary(items))
        result
    end
  end

  defp betamax_playback(request, tape) do
    response = Betamax.Tape.read(tape)
    {request, response}
  end

  defp betamax_record(request, response, tape) do
    :ok = Betamax.Tape.write(tape, response)
    {request, response}
  end

  defp prepend_response_steps(request, steps) do
    update_in(request.response_steps, &(steps ++ &1))
  end
end

defmodule Betamax.Tape do
  use Agent

  def start_link(items) do
    Agent.start_link(fn -> items end)
  end

  def read(tape) do
    Agent.get_and_update(tape, fn items ->
      [head | tail] = items
      {head, tail}
    end)
  end

  def write(tape, item) do
    Agent.update(tape, fn items -> [item | items] end)
  end

  def items(tape) do
    Agent.get(tape, & &1)
  end
end

Main.main()
