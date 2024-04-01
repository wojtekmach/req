defmodule Req.DecompressError do
  @moduledoc """
  Represents an error when decompression fails, returned by `Req.Steps.decompress_body/1`.
  """

  defexception [:format, :data, :reason]

  @impl true
  def message(%{format: format, reason: nil}) do
    "#{format} decompression failed"
  end

  @impl true
  def message(%{format: format, reason: reason}) do
    "#{format} decompression failed, reason: #{inspect(reason)}"
  end
end
