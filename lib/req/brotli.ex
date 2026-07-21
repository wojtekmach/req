defmodule Req.Brotli do
  @moduledoc false

  ## Encode

  def encode_init do
    :brotli_encoder.new()
  end

  def encode_chunk(encoder, data) do
    {:ok, compressed} = :brotli_encoder.append(encoder, data)
    IO.iodata_to_binary(compressed)
  end

  def encode_finish(encoder) do
    {:ok, compressed} = :brotli_encoder.finish(encoder)
    compressed
  end

  def encode(data) do
    IO.iodata_to_binary(encode_to_iodata(data))
  end

  def encode_to_iodata(data) do
    {:ok, compressed} = :brotli.encode(data)
    compressed
  end

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

  def decode_init do
    :brotli_decoder.new()
  end

  def decode_chunk(decoder, data) do
    case :brotli_decoder.stream(decoder, data) do
      {status, decompressed} when status in [:ok, :more] ->
        {:ok, IO.iodata_to_binary(decompressed)}

      :error ->
        {:error, :brotli_error}
    end
  end

  def decode_finish(decoder) do
    if :brotli_decoder.is_finished(decoder) do
      {:ok, ""}
    else
      {:error, :brotli_error}
    end
  end

  def decode_close(_decoder) do
    :ok
  end

  def decode(data) do
    case :brotli.decode(data) do
      {:ok, decompressed} ->
        {:ok, IO.iodata_to_binary(decompressed)}

      :error ->
        {:error, :brotli_error}
    end
  end

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
