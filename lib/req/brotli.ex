defmodule Req.Brotli do
  @moduledoc """
  [Brotli] decoding using [`:brotli`] package.

  This module is used by [`decompress_body`] on `content-encoding: br`.

  [Brotli]: https://github.com/google/brotli
  [`:brotli`]: https://brotli.hexdocs.pm/
  [`decompress_body`]: `Req.Steps.decompress_body/1`
  """

  ## Encode

  @doc false
  def encode_init do
    :brotli_encoder.new()
  end

  @doc false
  def encode_chunk(encoder, data) do
    {:ok, compressed} = :brotli_encoder.append(encoder, data)
    IO.iodata_to_binary(compressed)
  end

  @doc false
  def encode_finish(encoder) do
    {:ok, compressed} = :brotli_encoder.finish(encoder)
    compressed
  end

  @doc false
  def encode(data) do
    IO.iodata_to_binary(encode_to_iodata(data))
  end

  @doc false
  def encode_to_iodata(data) do
    {:ok, compressed} = :brotli.encode(data)
    compressed
  end

  @doc false
  def encode_to_stream(enumerable) do
    Stream.transform(
      enumerable,
      fn ->
        encode_init()
      end,
      fn data, encoder ->
        case encode_chunk(encoder, data) do
          "" ->
            {[], encoder}

          compressed ->
            {[compressed], encoder}
        end
      end,
      fn encoder ->
        {encode_finish(encoder), encoder}
      end,
      fn _encoder ->
        :ok
      end
    )
  end

  ## Decode

  @doc false
  def decode_init do
    :brotli_decoder.new()
  end

  @doc false
  def decode_chunk(decoder, data) do
    case :brotli_decoder.stream(decoder, data) do
      {status, decompressed} when status in [:ok, :more] ->
        {:ok, IO.iodata_to_binary(decompressed)}

      :error ->
        {:error, :brotli_error}
    end
  end

  @doc false
  def decode_finish(decoder) do
    if :brotli_decoder.is_finished(decoder) do
      {:ok, ""}
    else
      {:error, :brotli_error}
    end
  end

  @doc false
  def decode_close(_decoder) do
    :ok
  end

  @doc false
  def decode(data) do
    case :brotli.decode(data) do
      {:ok, decompressed} ->
        {:ok, IO.iodata_to_binary(decompressed)}

      :error ->
        {:error, :brotli_error}
    end
  end

  @doc false
  def decode_stream(enumerable) do
    Stream.transform(
      enumerable,
      fn -> decode_init() end,
      fn data, decoder ->
        case decode_chunk(decoder, data) do
          {:ok, ""} ->
            {[], decoder}

          {:ok, decompressed} ->
            {[decompressed], decoder}

          {:error, reason} ->
            :erlang.error(reason)
        end
      end,
      fn decoder ->
        case decode_finish(decoder) do
          {:ok, ""} ->
            {[], decoder}

          {:ok, decompressed} ->
            {[decompressed], decoder}

          {:error, reason} ->
            :erlang.error(reason)
        end
      end,
      fn _decoder -> :ok end
    )
  end
end
