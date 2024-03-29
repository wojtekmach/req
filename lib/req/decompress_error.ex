defmodule Req.DecompressError do
  @moduledoc """
  Represents an error when decompression fails, returned by `Req.Steps.decompress_body/1`.
  """

  defexception [:format, :data]

  @impl true
  def message(%{format: format}) do
    "decompression failed with format \'#{format}\'"
  end
end
