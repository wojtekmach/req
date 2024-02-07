defmodule Req.Test do
  @ownership Req.Ownership

  def stub(name) do
    case NimbleOwnership.get_owned(@ownership, self()) do
      %{^name => %{value: value}} ->
        value

      nil ->
        raise "cannot find stub #{inspect(name)} in process #{inspect(self())}"
    end
  end

  def stub(name, value) do
    NimbleOwnership.allow(@ownership, self(), self(), name)
    NimbleOwnership.get_and_update(@ownership, self(), name, fn _ -> {:ok, %{value: value}} end)
  end
end
