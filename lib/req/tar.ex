defmodule Req.Tar do
  @moduledoc """
  Tar archive decoding.
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
end
