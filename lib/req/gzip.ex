defmodule Req.Gzip do
  @moduledoc """
  [gzip] decoding using [`:zlib`].

  This module is used by [`decode_body`] on `.gz`, `application/gzip`, and `application/x-gzip`
  and by [`decompress_body`] on `content-encoding: gzip`.

  [gzip]: https://en.wikipedia.org/wiki/Gzip
  [`:zlib`]: `:zlib`
  [`decode_body`]: `Req.Steps.decode_body/1`
  [`decompress_body`]: `Req.Steps.decompress_body/1`
  """

  ## Encode

  @doc false
  def encode_init do
    z = :zlib.open()
    # 16 + 15 means gzip format with 15 window bits, copied from :zlib.gzip/1
    :ok = :zlib.deflateInit(z, :default, :deflated, 16 + 15, 8, :default)
    z
  end

  @doc false
  def encode_chunk(z, data) do
    IO.iodata_to_binary(:zlib.deflate(z, data))
  end

  @doc false
  def encode_finish(z) do
    compressed = IO.iodata_to_binary(:zlib.deflate(z, [], :finish))
    :ok = :zlib.deflateEnd(z)
    :ok = :zlib.close(z)
    compressed
  end

  @doc false
  def encode(data) do
    IO.iodata_to_binary(encode_to_iodata(data))
  end

  @doc false
  def encode_to_iodata(data) do
    :zlib.gzip(data)
  end

  @doc false
  def encode_to_stream(enumerable) do
    Stream.transform(
      enumerable,
      fn -> encode_init() end,
      fn data, z ->
        case encode_chunk(z, data) do
          "" ->
            {[], z}

          compressed ->
            {[compressed], z}
        end
      end,
      fn z -> {[encode_finish(z)], :closed} end,
      fn
        :closed ->
          :ok

        z ->
          :ok = :zlib.close(z)
      end
    )
  end

  ## Decode

  @doc false
  def decode_init do
    z = :zlib.open()
    :ok = :zlib.inflateInit(z, 16 + 15, :reset)
    z
  end

  @doc false
  def decode_chunk(z, data) do
    decompressed = IO.iodata_to_binary(safe_inflate(z, data))
    {:ok, decompressed}
  rescue
    e in ErlangError ->
      if e.original == :data_error do
        {:error, :data_error}
      else
        reraise e, __STACKTRACE__
      end
  end

  @doc false
  def decode_finish(z) do
    :ok = :zlib.inflateEnd(z)
    :ok = :zlib.close(z)
    {:ok, ""}
  rescue
    e in ErlangError ->
      if e.original == :data_error do
        {:error, :data_error}
      else
        reraise e, __STACKTRACE__
      end
  end

  @doc false
  def decode_close(z) do
    :ok = :zlib.close(z)
  end

  @doc false
  def decode(data) do
    {:ok, :zlib.gunzip(data)}
  rescue
    e in ErlangError ->
      if e.original == :data_error do
        {:error, :data_error}
      else
        reraise e, __STACKTRACE__
      end
  end

  @doc false
  def decode_stream(enumerable) do
    Stream.transform(
      enumerable,
      fn -> decode_init() end,
      fn data, z ->
        case decode_chunk(z, data) do
          {:ok, ""} ->
            {[], z}

          {:ok, decompressed} ->
            {[decompressed], z}

          {:error, reason} ->
            :erlang.error(reason)
        end
      end,
      fn z ->
        case decode_finish(z) do
          {:ok, ""} ->
            {[], :closed}

          {:ok, decompressed} ->
            {[decompressed], :closed}

          {:error, reason} ->
            :erlang.error(reason)
        end
      end,
      fn
        :closed ->
          :ok

        z ->
          decode_close(z)
      end
    )
  end

  defp safe_inflate(z, data) do
    case :zlib.safeInflate(z, data) do
      {:continue, output} ->
        [output | safe_inflate(z, [])]

      {:finished, output} ->
        output
    end
  end
end
