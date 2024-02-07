defmodule Req.Test do
  @ownership Req.Ownership

  @doc """
  Returns the stub created by `stub/2`.
  """
  def stub(name) do
    case NimbleOwnership.fetch_owner(@ownership, callers(), name) do
      {:ok, owner} when is_pid(owner) ->
        %{^name => value} = NimbleOwnership.get_owned(@ownership, owner)
        value

      :error ->
        raise "cannot find stub #{inspect(name)} in process #{inspect(self())}"
    end
  end

  @doc """
  Creates a stub with given `name` and `value`.

  This function allows stubbing _any_ value and later access it with `stub/1`. It is safe to use
  in concurrent tests.

  See [module documentation](`Req.Test`) for more examples.

  ## Examples

      iex> Req.Test.stub(MyStub, :foo)
      iex> Req.Test.stub(MyStub)
      :foo
      iex> Task.async(fn -> Req.Test.stub(MyStub) end) |> Task.await()
      :foo
  """
  def stub(name, value) do
    NimbleOwnership.get_and_update(@ownership, self(), name, fn _ -> {:ok, value} end)
  end

  defp callers do
    [self() | Process.get(:"$callers") || []]
  end
end
