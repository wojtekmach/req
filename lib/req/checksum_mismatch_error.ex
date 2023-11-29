defmodule Req.ChecksumMismatchError do
  defexception [:expected, :actual]

  def message(%{expected: expected, actual: actual}) do
    """
    checksum mismatch
    expected: #{expected}
    actual:   #{actual}\
    """
  end
end
