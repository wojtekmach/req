defmodule Req.Retry do
  @moduledoc false

  require Logger

  def retry({request, response_or_exception}) do
    retry =
      case Map.get(request.options, :retry, :safe_transient) do
        :safe_transient ->
          request.method in [:get, :head] and transient?(response_or_exception)

        :transient ->
          transient?(response_or_exception)

        false ->
          false

        fun when is_function(fun) ->
          apply_retry(fun, request, response_or_exception)

        :safe ->
          IO.warn("setting `retry: :safe` is deprecated in favour of `retry: :safe_transient`")
          request.method in [:get, :head] and transient?(response_or_exception)

        :never ->
          IO.warn("setting `retry: :never` is deprecated in favour of `retry: false`")
          false

        other ->
          raise ArgumentError,
                "expected :retry to be :safe_transient, :transient, false, or a 2-arity function, " <>
                  "got: #{inspect(other)}"
      end

    case retry do
      {:delay, delay} ->
        if !Req.Request.get_option(request, :retry_delay) do
          retry(request, response_or_exception, delay)
        else
          raise ArgumentError,
                "expected :retry_delay not to be set when the :retry function is returning `{:delay, milliseconds}`"
        end

      true ->
        retry(request, response_or_exception)

      retry when retry in [false, nil] ->
        {request, response_or_exception}
    end
  end

  defp apply_retry(fun, request, response_or_exception)

  defp apply_retry(fun, _request, response_or_exception) when is_function(fun, 1) do
    IO.warn("`retry: fun/1` has been deprecated in favor of `retry: fun/2`")
    fun.(response_or_exception)
  end

  defp apply_retry(fun, request, response_or_exception) when is_function(fun, 2) do
    fun.(request, response_or_exception)
  end

  defp transient?(%Req.Response{status: status}) when status in [408, 429, 500, 502, 503, 504] do
    true
  end

  defp transient?(%Req.Response{}) do
    false
  end

  defp transient?(%Req.TransportError{reason: reason})
       when reason in [:timeout, :econnrefused, :closed] do
    true
  end

  defp transient?(%Req.HTTPError{protocol: :http2, reason: reason})
       when reason in [:unprocessed, :pool_not_available] do
    true
  end

  defp transient?(%{__exception__: true}) do
    false
  end

  defp retry(request, response_or_exception, delay_or_nil \\ nil)

  defp retry(request, response_or_exception, nil) do
    do_retry(request, response_or_exception, &get_retry_delay/3)
  end

  defp retry(request, response_or_exception, delay) when is_integer(delay) do
    do_retry(request, response_or_exception, fn request, _, _ -> {request, delay} end)
  end

  defp do_retry(request, response_or_exception, delay_getter) do
    retry_count = Req.Request.get_private(request, :req_retry_count, 0)
    {request, delay} = delay_getter.(request, response_or_exception, retry_count)
    max_retries = Req.Request.get_option(request, :max_retries, 3)
    log_level = Req.Request.get_option(request, :retry_log_level, :warning)

    if retry_count < max_retries do
      log_retry(response_or_exception, retry_count, max_retries, delay, log_level)
      Process.sleep(delay)
      request = Req.Request.put_private(request, :req_retry_count, retry_count + 1)
      {request, response_or_exception} = Req.Request.run_request(%{request | halted: false})
      Req.Request.halt(request, response_or_exception)
    else
      {request, response_or_exception}
    end
  end

  defp get_retry_delay(request, %Req.Response{status: status} = response, retry_count)
       when status in [429, 503] do
    case Req.Request.fetch_option(request, :retry_delay) do
      {:ok, _retry_delay} ->
        calculate_retry_delay(request, retry_count)

      :error ->
        if delay = Req.Response.get_retry_after(response) do
          {request, delay}
        else
          calculate_retry_delay(request, retry_count)
        end
    end
  end

  defp get_retry_delay(request, _response, retry_count) do
    calculate_retry_delay(request, retry_count)
  end

  defp calculate_retry_delay(request, retry_count) do
    case Req.Request.get_option(request, :retry_delay, &exp_backoff_with_jitter/1) do
      delay when is_integer(delay) ->
        {request, delay}

      fun when is_function(fun, 1) ->
        case fun.(retry_count) do
          delay when is_integer(delay) and delay >= 0 ->
            {request, delay}

          other ->
            raise ArgumentError,
                  "expected :retry_delay function to return non-negative integer, got: #{inspect(other)}"
        end
    end
  end

  defp exp_backoff_with_jitter(n) do
    trunc(Integer.pow(2, n) * 1000 * (1 - 0.1 * :rand.uniform()))
  end

  defp log_retry(_, _, _, _, false), do: :ok

  defp log_retry(response_or_exception, retry_count, max_retries, delay, level) do
    retries_left =
      case max_retries - retry_count do
        1 -> "1 attempt"
        n -> "#{n} attempts"
      end

    message = ["will retry in #{delay}ms, ", retries_left, " left"]

    case response_or_exception do
      %{__exception__: true} = exception ->
        Logger.log(level, [
          "retry: got exception, ",
          message
        ])

        Logger.log(level, [
          "** (#{inspect(exception.__struct__)}) ",
          Exception.message(exception)
        ])

      response ->
        Logger.log(level, ["retry: got response with status #{response.status}, ", message])
    end
  end
end
