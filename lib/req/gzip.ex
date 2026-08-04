defmodule Req.Gzip do
  @moduledoc """
  [gzip] decoding using [`:zlib`].

  This module is used by `Req.Decode` on `.gz`, `application/gzip`, and `application/x-gzip`
  and by `Req.Decompress` on `content-encoding: gzip`.

  [gzip]: https://en.wikipedia.org/wiki/Gzip
  [`:zlib`]: `:zlib`
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
  def decode_init(:buffer) do
    {:buffer, ""}
  end

  def decode_init(:stream) do
    {:stream, decode_init()}
  end

  @doc false
  def decode_chunk({:buffer, buffer}, data) do
    {:ok, data, {:buffer, [buffer | data]}}
  end

  def decode_chunk({:stream, z} = state, data) do
    case IO.iodata_to_binary(safe_inflate(z, data)) do
      "" -> {:ok, nil, state}
      decompressed -> {:ok, decompressed, state}
    end
  rescue
    err in ErlangError ->
      if err.original == :data_error do
        {:error, %Req.DecompressError{format: :gzip, data: data, reason: :data_error}}
      else
        reraise err, __STACKTRACE__
      end
  end

  def decode_chunk(z, data) do
    case IO.iodata_to_binary(safe_inflate(z, data)) do
      "" -> {:ok, nil, z}
      decompressed -> {:ok, decompressed, z}
    end
  rescue
    e in ErlangError ->
      if e.original == :data_error do
        {:error, %Req.DecompressError{format: :gzip, data: data, reason: :data_error}}
      else
        reraise e, __STACKTRACE__
      end
  end

  @doc false
  def decode_finish({:buffer, buffer}) do
    decode(IO.iodata_to_binary(buffer))
  end

  def decode_finish({:stream, z}) do
    decode_finish(z)
  end

  def decode_finish(z) do
    :ok = :zlib.inflateEnd(z)
    :ok = :zlib.close(z)
    {:ok, nil}
  rescue
    e in ErlangError ->
      if e.original == :data_error do
        {:error, %Req.DecompressError{format: :gzip, reason: :data_error}}
      else
        reraise e, __STACKTRACE__
      end
  end

  @doc false
  def decode_close({:buffer, _buffer}) do
    :ok
  end

  def decode_close({:stream, z}) do
    decode_close(z)
  end

  def decode_close(z) do
    :ok = :zlib.close(z)
  end

  @doc false
  def decode(data) do
    {:ok, :zlib.gunzip(data)}
  rescue
    e in ErlangError ->
      if e.original == :data_error do
        {:error, %Req.DecompressError{format: :gzip, data: data, reason: :data_error}}
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
          {:ok, nil, z} ->
            {[], z}

          {:ok, decompressed, z} ->
            {[decompressed], z}

          {:error, exception} ->
            raise exception
        end
      end,
      fn z ->
        case decode_finish(z) do
          {:ok, nil} ->
            {[], :closed}

          {:error, exception} ->
            raise exception
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
