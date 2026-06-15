defmodule Req.ZIP do
  @moduledoc """
  ZIP archive decoding.
  """

  @doc """
  Decodes a ZIP archive `binary` into a list of `{name, contents}` entries.

  Returns `{:ok, entries}` or `{:error, exception}`.
  """
  @spec decode(binary()) :: {:ok, [{binary(), binary()}]} | {:error, %Req.ArchiveError{}}
  def decode(binary) when is_binary(binary) do
    case :zip.extract(binary, [:memory]) do
      {:ok, files} ->
        files =
          for {path, contents} <- files do
            {List.to_string(path), contents}
          end

        {:ok, files}

      {:error, _reason} ->
        {:error, %Req.ArchiveError{format: :zip, data: binary}}
    end
  end
end
