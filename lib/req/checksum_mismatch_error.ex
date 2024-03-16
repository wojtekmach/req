defmodule Req.ChecksumMismatchError do
  @moduledoc """
  Represents a checksum mismatch error returned by `Req.Steps.checksum/1`.
  """

  defexception [:expected, :actual]

  @impl true
  def message(%{expected: expected, actual: actual}) do
    """
    checksum mismatch
    expected: #{expected}
    actual:   #{actual}\
    """
  end
end
