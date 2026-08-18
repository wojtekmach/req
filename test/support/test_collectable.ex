defmodule TestCollectable do
  defstruct []

  defimpl Collectable do
    def into(%TestCollectable{} = collectable) do
      pid = self()
      send(pid, :open)

      collector = fn
        nil, {:cont, data} ->
          send(pid, {:cont, data})
          nil

        nil, :done ->
          send(pid, :done)
          collectable

        nil, :halt ->
          send(pid, :halt)
          collectable
      end

      {nil, collector}
    end
  end
end
