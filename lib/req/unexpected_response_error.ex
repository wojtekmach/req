defmodule Req.UnexpectedResponseError do
  defexception [:expected, :response]

  @impl true
  def message(%{expected: expected, response: response}) do
    """
    expected status #{inspect(expected)}, got: #{response.status}

    headers:
    #{inspect(response.headers, pretty: true)}

    body:
    #{inspect(response.body, pretty: true)}\
    """
  end
end
