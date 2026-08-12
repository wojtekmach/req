defmodule Req.Tar do
  @moduledoc """
  Tar archive decoding using [`:erl_tar`].

  `Req.Decode` can use this module for `.tar`, `.tgz`, `.tar.gz`, and `application/x-tar`
  responses when the `:tar` or `:tgz` decoder is enabled via the `:decoders` option.

  [`:erl_tar`]: `:erl_tar`
  """

  @doc """
  Decodes a tar archive `binary` into a list of `{name, contents}` entries.

  The binary may be a plain tar archive or a gzip-compressed one (`.tar.gz`/`.tgz`); the
  compression is detected automatically.

  Returns `{:ok, entries}` or `{:error, exception}`.
  """
  @spec decode(binary()) :: {:ok, [{charlist(), binary()}]} | {:error, %Req.ArchiveError{}}
  def decode(binary) when is_binary(binary) do
    case :erl_tar.extract({:binary, binary}, [:memory | modes(binary)]) do
      {:ok, files} ->
        {:ok, files}

      {:error, reason} ->
        {:error, %Req.ArchiveError{format: :tar, data: binary, reason: reason}}
    end
  end

  # gzip magic bytes
  defp modes(<<0x1F, 0x8B, _::binary>>), do: [:compressed]
  defp modes(_binary), do: []

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
