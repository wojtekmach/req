defmodule Req.ArchiveError do
  @moduledoc """
  Represents an error when unpacking archives fails, returned by the archive decoders.
  See `Req.Decode`.
  """

  defexception [:format, :data, :reason]

  @impl true
  def message(%{format: :tar, reason: reason}) do
    "tar unpacking failed: #{:erl_tar.format_error(reason)}"
  end

  @impl true
  def message(%{format: format, reason: nil}) do
    "#{format} unpacking failed"
  end

  @impl true
  def message(%{format: format, reason: reason}) do
    "#{format} unpacking failed: #{inspect(reason)}"
  end
end
