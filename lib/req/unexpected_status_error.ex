defmodule Req.UnexpectedStatusError do
  @moduledoc """
  An exception returned by `Req.Expect` when response has unexpected status.

  The public fields are:

    * `:expected_status` - the expected HTTP response status

    * `:actual_status` - the actual HTTP response status
  """

  defexception [:expected_status, :actual_status]

  @impl true
  def message(%{expected_status: expected_status, actual_status: actual_status}) do
    "expected response status #{format(expected_status)}, got: #{inspect(actual_status)}"
  end

  defp format(expected_status) when is_atom(expected_status) do
    "#{inspect(expected_status)} (#{inspect(range(expected_status))})"
  end

  defp format(expected_status) do
    inspect(expected_status)
  end

  defp range(:informational), do: 100..199
  defp range(:successful), do: 200..299
  defp range(:redirection), do: 300..399
  defp range(:client_error), do: 400..499
  defp range(:server_error), do: 500..599
end
