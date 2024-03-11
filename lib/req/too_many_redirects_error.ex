defmodule Req.TooManyRedirectsError do
  defexception [:max_redirects]

  def message(%{max_redirects: max_redirects}) do
    "too many redirects (#{max_redirects})"
  end
end
