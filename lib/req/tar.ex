defmodule Req.Tar do
  @moduledoc """
  Tar archive decoding using [`:erl_tar`].

  This module is used by `Req.Decode` on `.tar`, `.tgz`, `.tar.gz`, and `application/x-tar`.

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
  def decode_init do
    nil
  end

  @doc false
  def decode_chunk(state, data) do
    {:ok, data, state}
  end

  @doc false
  def decode_finish(_state) do
    {:ok, nil}
  end

  @doc false
  def decode_close(_state) do
    :ok
  end
end
