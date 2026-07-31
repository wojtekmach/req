defmodule Req.Zstd do
  @moduledoc """
  [Zstandard] decoding using [`:zstd`].

  This module is used by [`decode_body`] on `.zst` and `application/zstd` and by
  [`decompress_body`] on `content-encoding: zstd`.

  [`:zstd`] requires Erlang/OTP 28+.

  [Zstandard]: https://facebook.github.io/zstd/
  [`:zstd`]: `:zstd`
  [`decode_body`]: `Req.Steps.decode_body/1`
  [`decompress_body`]: `Req.Steps.decompress_body/1`
  """

  ## Encode

  @doc false
  def encode_init do
    {:ok, ctx} = :zstd.context(:compress)
    ctx
  end

  @doc false
  def encode_chunk(ctx, data) do
    IO.iodata_to_binary(stream(ctx, data))
  end

  @doc false
  def encode_finish(ctx) do
    {:done, compressed} = :zstd.finish(ctx, "")
    :ok = :zstd.close(ctx)
    IO.iodata_to_binary(compressed)
  end

  @doc false
  def encode(data) do
    IO.iodata_to_binary(encode_to_iodata(data))
  end

  @doc false
  def encode_to_iodata(data) do
    :zstd.compress(data)
  end

  @doc false
  def encode_to_stream(enumerable) do
    Stream.transform(
      enumerable,
      fn -> encode_init() end,
      fn data, ctx ->
        case encode_chunk(ctx, data) do
          "" ->
            {[], ctx}

          compressed ->
            {[compressed], ctx}
        end
      end,
      fn ctx -> {[encode_finish(ctx)], :closed} end,
      fn
        :closed ->
          :ok

        ctx ->
          :ok = :zstd.close(ctx)
      end
    )
  end

  ## Decode

  @doc false
  def decode_init do
    {:ok, ctx} = :zstd.context(:decompress)
    ctx
  end

  @doc false
  def decode_chunk(ctx, data) do
    decompressed = IO.iodata_to_binary(stream(ctx, data))
    {:ok, decompressed}
  rescue
    e in ErlangError ->
      case e.original do
        {:zstd_error, reason} ->
          {:error, reason}

        _ ->
          reraise e, __STACKTRACE__
      end
  end

  @doc false
  def decode_finish(ctx) do
    {:done, decompressed} = :zstd.finish(ctx, "")
    :ok = :zstd.close(ctx)
    {:ok, IO.iodata_to_binary(decompressed)}
  rescue
    e in ErlangError ->
      case e.original do
        {:zstd_error, reason} ->
          {:error, reason}

        _ ->
          reraise e, __STACKTRACE__
      end
  end

  @doc false
  def decode_close(ctx) do
    :ok = :zstd.close(ctx)
  end

  @doc false
  def decode(data) do
    decompressed = IO.iodata_to_binary(:zstd.decompress(data))
    {:ok, decompressed}
  rescue
    e in ErlangError ->
      case e.original do
        {:zstd_error, reason} ->
          {:error, reason}

        _ ->
          reraise e, __STACKTRACE__
      end
  end

  @doc false
  def decode_stream(enumerable) do
    Stream.transform(
      enumerable,
      fn -> decode_init() end,
      fn data, ctx ->
        case decode_chunk(ctx, data) do
          {:ok, ""} ->
            {[], ctx}

          {:ok, decompressed} ->
            {[decompressed], ctx}

          {:error, reason} ->
            :erlang.error(reason)
        end
      end,
      fn ctx ->
        case decode_finish(ctx) do
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

        ctx ->
          decode_close(ctx)
      end
    )
  end

  defp stream(ctx, data) do
    case :zstd.stream(ctx, data) do
      {:continue, output} ->
        output

      {:continue, remainder, output} ->
        [output | stream(ctx, remainder)]
    end
  end
end
