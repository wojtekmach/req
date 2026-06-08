defmodule Req.ZIP do
  @moduledoc """
  ZIP archive decoding.
  """

  @doc """
  Decodes a ZIP archive `binary` into a list of `{name, contents}` entries.

  Returns `{:ok, entries}` or `{:error, exception}`.
  """
  @spec decode(binary()) :: {:ok, [{charlist(), binary()}]} | {:error, %Req.ArchiveError{}}
  def decode(binary) when is_binary(binary) do
    case :zip.extract(binary, [:memory]) do
      {:ok, files} ->
        {:ok, files}

      {:error, _reason} ->
        # :zip surfaces an internal `{:badmatch, _}` term here, which is not useful.
        {:error, %Req.ArchiveError{format: :zip, data: binary}}
    end
  end
end
