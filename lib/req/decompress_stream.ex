defmodule Req.DecompressStream do
  @moduledoc false

  require Logger

  def stream_start(resp) do
    accepted =
      resp.request
      |> Req.Request.get_header("accept-encoding")
      |> Enum.flat_map(fn value ->
        for token <- String.split(value, ",", trim: true) do
          token |> String.split(";", parts: 2) |> hd() |> String.trim() |> String.downcase(:ascii)
        end
      end)

    codecs =
      resp
      |> Req.Response.get_header("content-encoding")
      |> Enum.flat_map(&String.split(&1, ",", trim: true))
      |> Enum.map(&(&1 |> String.trim() |> String.downcase(:ascii)))
      |> Enum.map(fn
        "x-gzip" -> "gzip"
        codec -> codec
      end)
      |> Enum.reject(&(&1 == "identity"))

    for codec <- codecs, not supported?(codec) do
      Logger.debug("algorithm #{inspect(codec)} is not supported")
    end

    if codecs != [] and Enum.all?(codecs, &(&1 in accepted and supported?(&1))) do
      # content-encoding lists encodings in the order they were applied,
      # so decompress in reverse order.
      codecs |> Enum.reverse() |> Enum.map(&start_codec/1)
    else
      :identity
    end
  end

  defp supported?("gzip"), do: true
  defp supported?("br"), do: Code.ensure_loaded?(:brotli_decoder)
  defp supported?("zstd"), do: System.otp_release() >= "28"
  defp supported?(_codec), do: false

  defp start_codec("gzip") do
    z = :zlib.open()
    :ok = :zlib.inflateInit(z, 31)
    {:gzip, z}
  end

  defp start_codec("br") do
    {:br, :brotli_decoder.new()}
  end

  defp start_codec("zstd") do
    {:ok, ctx} = :zstd.context(:decompress)
    {:zstd, ctx}
  end

  def stream_chunk(data, :identity) do
    {:ok, [data], :identity}
  end

  def stream_chunk(data, codecs) when is_list(codecs) do
    case chunk_chain([data], codecs) do
      {:ok, datas} -> {:ok, datas, codecs}
      {:error, exception} -> {:error, exception, codecs}
    end
  end

  def stream_finish(:identity) do
    {:ok, [], :identity}
  end

  def stream_finish(codecs) when is_list(codecs) do
    finish_chain(codecs, [])
  end

  defp chunk_chain(datas, []) do
    {:ok, datas}
  end

  defp chunk_chain(datas, [codec | rest]) do
    result =
      Enum.reduce_while(datas, {:ok, []}, fn data, {:ok, acc} ->
        case codec_chunk(data, codec) do
          {:ok, datas} -> {:cont, {:ok, acc ++ datas}}
          {:error, exception} -> {:halt, {:error, exception}}
        end
      end)

    with {:ok, datas} <- result do
      chunk_chain(datas, rest)
    end
  end

  defp finish_chain([], datas) do
    {:ok, datas, :identity}
  end

  defp finish_chain([codec | rest] = codecs, datas) do
    with {:ok, flushed} <- codec_finish(codec),
         {:ok, flushed} <- chunk_chain(flushed, rest) do
      finish_chain(rest, datas ++ flushed)
    else
      {:error, exception} -> {:error, exception, codecs}
    end
  end

  defp codec_chunk(data, {:gzip, z}) do
    emit(:zlib.inflate(z, data))
  catch
    :error, _reason ->
      {:error, %Req.DecompressError{format: :gzip, data: data}}
  end

  defp codec_chunk(data, {:br, decoder}) do
    case :brotli_decoder.stream(decoder, data) do
      {status, iodata} when status in [:ok, :more] ->
        emit(iodata)

      :error ->
        {:error, %Req.DecompressError{format: :br, data: data}}
    end
  end

  defp codec_chunk(data, {:zstd, ctx}) do
    {_status, iodata} = :zstd.stream(ctx, data)
    emit(iodata)
  catch
    :error, reason ->
      {:error, %Req.DecompressError{format: :zstd, data: data, reason: zstd_reason(reason)}}
  end

  defp codec_finish({:gzip, z}) do
    :ok = :zlib.inflateEnd(z)
    :ok = :zlib.close(z)
    {:ok, []}
  catch
    :error, _reason ->
      {:error, %Req.DecompressError{format: :gzip}}
  end

  # The brotli decoder accepts a truncated stream chunk by chunk without complaint, so verify at
  # the end that it actually reached the end of the brotli stream.
  defp codec_finish({:br, decoder}) do
    if :brotli_decoder.is_finished(decoder) do
      {:ok, []}
    else
      {:error, %Req.DecompressError{format: :br}}
    end
  end

  defp codec_finish({:zstd, ctx}) do
    {:done, iodata} = :zstd.finish(ctx, "")
    emit(iodata)
  catch
    :error, reason ->
      {:error, %Req.DecompressError{format: :zstd, reason: zstd_reason(reason)}}
  end

  defp zstd_reason({:zstd_error, reason}), do: reason
  defp zstd_reason(reason), do: reason

  defp emit(iodata) do
    case IO.iodata_to_binary(iodata) do
      "" -> {:ok, []}
      binary -> {:ok, [binary]}
    end
  end
end
