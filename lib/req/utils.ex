defmodule Req.Utils do
  @moduledoc false

  defmodule CollectableWith do
    defstruct [:collectable, :init_fun, :fun, :acc, :collector]

    defimpl Collectable do
      def into(%{acc: acc, collector: collector, init_fun: init_fun, fun: fun}) do
        new_collector = fn {acc, state}, command ->
          {command, state} = fun.(command, state)
          {collector.(acc, command), state}
        end

        {init_fun.(acc, %{}), new_collector}
      end
    end
  end

  def collectable_with(collectable, init_fun, fun)

  def collectable_with(
        %Req.Utils.CollectableWith{init_fun: init_fun1, fun: fun1} = collectable,
        init_fun2,
        fun2
      ) do
    %{
      collectable
      | init_fun: fn acc, state ->
          {acc, state} = init_fun1.(acc, state)
          init_fun2.(acc, state)
        end,
        fun: fn command, state ->
          {command, state} = fun1.(command, state)
          fun2.(command, state)
        end
    }
  end

  def collectable_with(collectable, init_fun, fun) do
    {acc, collector} = Collectable.into(collectable)
    %Req.Utils.CollectableWith{acc: acc, collector: collector, init_fun: init_fun, fun: fun}
  end

  def with_hash(collectable, type) do
    collectable_with(
      collectable,
      fn acc, state ->
        {acc, Map.put(state, :hash, :crypto.hash_init(hash_type(type)))}
      end,
      fn
        {:cont, element}, state ->
          {{:cont, element}, update_in(state.hash, &:crypto.hash_update(&1, element))}

        :halt, state ->
          {:halt, state}

        :done, state ->
          {:done, update_in(state.hash, &:crypto.hash_final/1)}
      end
    )
  end

  defp hash_type(:sha1), do: :sha
  defp hash_type(other), do: other

  def with_gunzip(collectable) do
    # https://github.com/erlang/otp/blob/OTP-26.0/erts/preloaded/src/zlib.erl#L548:L558
    z = :zlib.open()
    :ok = :zlib.inflateInit(z, 16 + 15)

    collectable_with(
      collectable,
      fn acc, state ->
        {acc, state}
      end,
      fn
        {:cont, element}, state ->
          decompressed = IO.iodata_to_binary(:zlib.inflate(z, element))
          {{:cont, decompressed}, state}

        :halt, state ->
          :zlib.inflateEnd(z)
          :zlib.close(z)
          {:halt, state}

        :done, state ->
          :zlib.inflateEnd(z)
          :zlib.close(z)
          {:done, state}
      end
    )
  end
end
