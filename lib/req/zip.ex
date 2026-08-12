defmodule Req.ZIP do
  @moduledoc """
  ZIP archive decoding using [`:zip`].

  `Req.Decode` can use this module for `.zip` and `application/zip` responses when the `:zip`
  decoder is enabled via the `:decoders` option.

  [`:zip`]: `:zip`
  """

  @doc false
  def encode!(files) do
    {:ok, {"archive.zip", binary}} = :zip.create("archive.zip", files, [:memory])
    binary
  end

  @doc false
  def decode(binary) when is_binary(binary) do
    case :zip.extract(binary, [:memory]) do
      {:ok, files} ->
        {:ok, files}

      {:error, _reason} ->
        # :zip surfaces an internal `{:badmatch, _}` term here, which is not useful.
        {:error, %Req.ArchiveError{format: :zip, data: binary}}
    end
  end

  @doc false
  def decode!(binary) when is_binary(binary) do
    case decode(binary) do
      {:ok, decoded} ->
        decoded

      {:error, err} ->
        raise err
    end
  end

  @doc false
  def decode_init(:buffer) do
    {:buffer, ""}
  end

  def decode_init(:stream) do
    :stream
  end

  @doc false
  def decode_chunk({:buffer, buffer}, data) do
    {:ok, data, {:buffer, [buffer | data]}}
  end

  def decode_chunk(:stream, data) do
    {:ok, data, :stream}
  end

  @doc false
  def decode_finish({:buffer, buffer}) do
    decode(IO.iodata_to_binary(buffer))
  end

  def decode_finish(:stream) do
    {:ok, nil}
  end

  @doc false
  def decode_close(_state) do
    :ok
  end
end
