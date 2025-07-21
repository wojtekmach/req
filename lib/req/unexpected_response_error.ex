defmodule Req.UnexpectedResponseError do
  @moduledoc """
  An exception returned by `Req.Steps.expect/1` when response has unexpected status.

  The public fields are:

    * `:expected_status` - the expected HTTP response status

    * `:response` - the HTTP response
  """

  defexception [:expected_status, :response]

  @impl true
  def message(%{expected_status: expected_status, response: response}) do
    """
    expected status #{inspect(expected_status)}, got: #{response.status}

    headers:
    #{inspect(response.headers, pretty: true)}

    body:
    #{inspect(response.body, pretty: true)}\
    """
  end
end
