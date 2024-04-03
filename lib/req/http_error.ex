defmodule Req.HTTPError do
  @moduledoc """
  Represents an HTTP protocol error.

  This is a standardised exception that all Req adapters should use for HTTP-protocol-related
  errors.

  This exception is based on `Mint.HTTPError`.
  """

  defexception [:protocol, :reason]

  @impl true
  def message(%{protocol: :http1, reason: reason}) do
    Mint.HTTP1.format_error(reason)
  rescue
    FunctionClauseError ->
      "http1 error: #{inspect(reason)}"
  end

  def message(%{protocol: :http2, reason: reason}) do
    Mint.HTTP2.format_error(reason)
  rescue
    FunctionClauseError ->
      "http2 error: #{inspect(reason)}"
  end
end
