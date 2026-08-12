defmodule Req.Expect do
  @moduledoc """
  Expect that response matches the given status.

  This step ensures the HTTP response has the given expected status, otherwise it
  returns `Req.UnexpectedStatusError`.

  ## Request Options

    * `:expect` - the expected HTTP response status. Can be one of the following:

        * integer
        * range
        * atom - one of `:informational` (1xx), `:successful` (2xx), `:redirection` (3xx),
          `:client_error` (4xx), or `:server_error` (5xx)
        * list of integers/ranges/atoms

  > #### Order Matters! {: .info}
  >
  > By default, `Req.Expect` runs AFTER `Req.Retry`, `Req.Redirect`, `Req.Decompress`,
  > and `Req.Decode` steps.
  >
  > This means that, for example, HTTP 503 error would be first retried,
  > HTTP 307 redirect would be first followed, and the response body
  > would be first decompressed and decoded before checking for expected HTTP status.
  > If this is undesirable, re-arrange or disable and manually run given steps.

  ## Examples

      iex> resp = Req.get!("https://httpbingo.org/status/200", expect: 200)
      iex> resp.status
      200

      iex> Req.get!("https://httpbingo.org/status/404", expect: :successful)
      ** (Req.UnexpectedStatusError) expected response status :successful (200..299), got: 404
  """

  @doc false
  def stream(%Req.Request{} = req, acc, fun, state, next) do
    case next.(req, acc, fun, state) do
      {:ok, resp, acc, state} ->
        expect(resp.request, resp, acc, state)

      result ->
        result
    end
  end

  defp expect(req, resp, acc, state) do
    if Req.Request.get_option(req, :http_errors) do
      IO.warn("the `:http_errors` option is deprecated in favour of `:expect`")
    end

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

    expect = req.options[:expect]

    cond do
      is_nil(expect) ->
        {:ok, resp, acc, state}

      expect_success?(resp.status, expect) ->
        {:ok, resp, acc, state}

      true ->
        err =
          Req.UnexpectedStatusError.exception(
            expected_status: expect,
            actual_status: resp.status
          )

        {{:error, err}, resp, acc, state}
    end
  end

  defp expect_success?(status, status) do
    true
  end

  defp expect_success?(_, other_status) when is_integer(other_status) do
    false
  end

  defp expect_success?(status, %Range{} = statuses) do
    status in statuses
  end

  @status_category_atoms [:informational, :successful, :redirection, :client_error, :server_error]

  defp expect_success?(status, :informational), do: status in 100..199
  defp expect_success?(status, :successful), do: status in 200..299
  defp expect_success?(status, :redirection), do: status in 300..399
  defp expect_success?(status, :client_error), do: status in 400..499
  defp expect_success?(status, :server_error), do: status in 500..599

  defp expect_success?(status, [expect | tail])
       when is_integer(expect) or is_struct(expect, Range) or expect in @status_category_atoms do
    if expect_success?(status, expect) do
      true
    else
      expect_success?(status, tail)
    end
  end

  defp expect_success?(_status, []) do
    false
  end
end
