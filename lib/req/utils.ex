defmodule Req.Utils do
  @moduledoc false

  defmodule CollectableWith do
    defstruct [:collectable, :init, :fun]

    defimpl Collectable do
      def into(%{collectable: collectable, init: init, fun: fun}) do
        {acc, collector} = Collectable.into(collectable)

        new_collector = fn acc, command ->
          fun.(acc, collector, command)
        end

        {init.(acc), new_collector}
      end
    end
  end

  def collectable_with(collectable, init, fun) do
    %CollectableWith{collectable: collectable, init: init, fun: fun}
  end

  def with_hash(collectable, type) do
    collector = fn
      {acc, hash}, collector, {:cont, element} ->
        hash = :crypto.hash_update(hash, element)
        {collector.(acc, {:cont, element}), hash}

      {acc, hash}, collector, :done ->
        hash = :crypto.hash_final(hash)
        {collector.(acc, :done), hash}

      {acc, hash}, collector, :halt ->
        {collector.(acc, :halt), hash}
    end

    collectable_with(collectable, fn acc -> {acc, hash_init(type)} end, collector)
  end

  defp hash_init(:sha1), do: hash_init(:sha)
  defp hash_init(type), do: :crypto.hash_init(type)

  def with_gzip(collectable) do
    # https://github.com/erlang/otp/blob/OTP-26.0/erts/preloaded/src/zlib.erl#L548:L558
    z = :zlib.open()
    :ok = :zlib.deflateInit(z, :default, :deflated, 16 + 15, 8, :default)

    collector = fn
      acc, collector, {:cont, decompressed} ->
        compressed = IO.iodata_to_binary(:zlib.deflate(z, decompressed))
        collector.(acc, {:cont, compressed})

      acc, collector, :done ->
        compressed = IO.iodata_to_binary(:zlib.deflate(z, [], :finish))
        :zlib.deflateEnd(z)
        :zlib.close(z)
        acc = collector.(acc, {:cont, compressed})
        collector.(acc, :done)

      acc, collector, :halt ->
        :zlib.deflateEnd(z)
        :zlib.close(z)
        collector.(acc, :halt)
    end

    collectable_with(collectable, & &1, collector)
  end

  def with_gunzip(collectable) do
    z = :zlib.open()
    :ok = :zlib.inflateInit(z, 16 + 15)

    collector = fn
      acc, collector, {:cont, compressed} ->
        decompressed = IO.iodata_to_binary(:zlib.inflate(z, compressed))
        collector.(acc, {:cont, decompressed})

      acc, collector, :done ->
        :zlib.inflateEnd(z)
        :zlib.close(z)
        collector.(acc, :done)

      acc, collector, :halt ->
        :zlib.inflateEnd(z)
        :zlib.close(z)
        collector.(acc, :halt)
    end

    z = :zlib.open()
    :ok = :zlib.inflateInit(z, 16 + 15)
    collectable_with(collectable, & &1, collector)
  end
end
