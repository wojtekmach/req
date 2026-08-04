defmodule Req.ChecksumMismatchError do
  @moduledoc """
  Represents a checksum mismatch error, returned when the response body does not match
  the `:checksum` option. See `Req.Checksum`.
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
