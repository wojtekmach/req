defmodule Req.HTTPErrors do
  @moduledoc """
  Handles HTTP 4xx/5xx error responses.

  ## Request Options

    * `:http_errors` - how to handle HTTP 4xx/5xx error responses. Can be one of the following:

      * `:return` (default) - return the response

      * `:raise` - raise an error

  ## Examples

      iex> Req.get!("https://httpbin.org/status/404").status
      404

      iex> Req.get!("https://httpbin.org/status/404", http_errors: :raise)
      ** (RuntimeError) The requested URL returned error: 404
      Response body: ""
  """

  def stream(%Req.Request{} = req, acc, fun, state, next) do
    case next.(req, acc, fun, state) do
      {:ok, resp, acc, _state} = result ->
        handle_http_errors(resp.request, resp, acc)
        result

      result ->
        result
    end
  end

  defp handle_http_errors(req, resp, acc) do
    if is_integer(resp.status) and resp.status >= 400 and
         Map.get(req.options, :http_errors, :return) == :raise do
      body =
        case acc do
          %Req.Buffer{} = buffer ->
            Req.Buffer.body(buffer)

          _other ->
            resp.body
        end

      raise """
      The requested URL returned error: #{resp.status}
      Response body: #{inspect(body)}\
      """
    end

    :ok
  end
end
