defmodule Req.TooManyRedirectsError do
  @moduledoc """
  Represents an error when too many redirects occured, returned by `Req.Steps.redirect/1`.
  """

  defexception [:max_redirects]

  @impl true
  def message(%{max_redirects: max_redirects}) do
    "too many redirects (#{max_redirects})"
  end
end
