defmodule Req.DecompressError do
  @moduledoc """
  Represents an error when decompression fails, returned by `Req.Steps.decompress_body/1`.
  """

  defexception [:format, :data, :reason]

  @impl true
  def message(%{format: format, reason: reason}) when not is_nil(reason) do
    "#{message(%{format: format})}, reason: #{inspect(reason)}"
  end

  @impl true
  def message(%{format: format}) do
    "decompression failed with format \'#{format}\'"
  end
end
