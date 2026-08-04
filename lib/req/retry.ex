defmodule Req.Retry do
  @moduledoc """
  Retries a request on errors.

  ## Request Options

    * `:retry` - can be one of the following:

        * `:safe_transient` (default) - retry safe (GET/HEAD) requests on one of:

            * HTTP 408/429/500/502/503/504 responses

            * `Req.TransportError` with `reason: :timeout | :econnrefused | :closed`

            * `Req.HTTPError` with `protocol: :http2, reason: :unprocessed | :pool_not_available`

        * `:transient` - same as `:safe_transient` except retries all HTTP methods (POST, DELETE, etc.)

        * `fun` - a 2-arity function that accepts a `Req.Request` and either a `Req.Response` or an exception struct
          and returns one of the following:

            * `true` - retry with the default delay controller by default delay option described below.

            * `{:delay, milliseconds}` - retry with the given delay.

            * `false/nil` - don't retry.

        * `false` - don't retry.

    * `:retry_delay` - if not set, which is the default, the retry delay is determined by
      the value of the `Retry-After` header on HTTP 429/503 responses. If the header is not set,
      or the header value is negative, the default delay follows a simple exponential backoff
      with jitter, for example: 0.949s, 1.97s, 3.87s, 7.55s, ...

      `:retry_delay` can be set to a function that receives the retry count (starting at 0)
      and returns the delay, the number of milliseconds to sleep before making another attempt.

    * `:retry_log_level` - the log level to emit retry logs at. Can also be set to `false` to disable
      logging these messages. Defaults to `:warning`.

    * `:max_retries` - maximum number of retry attempts, defaults to `3` (for a total of `4`
      requests to the server, including the initial one.)

  ## Examples

      iex> Req.get!("https://httpbin.org/status/500,200").status
      # 08:43:19.101 [warning] retry: got response with status 500, will retry in 941ms, 2 attempts left
      # 08:43:22.958 [warning] retry: got response with status 500, will retry in 1877ms, 1 attempt left
      200
  """

  require Logger

  def stream(%Req.Request{} = req, acc, fun, state, next) do
    stream(req, acc, fun, state, next, _count = 0)
  end

  defp stream(req, acc, fun, state, next, count) do
    case next.(req, acc, fun, state) do
      {:ok, resp, _acc, _state} = result ->
        if retry(resp.request, resp, count) do
          with %Req.Response.Async{} <- resp.body do
            Req.cancel_async_response(resp)
          end

          req = put_in(req.private[:req_retry_count], count + 1)
          stream(req, acc, fun, state, next, count + 1)
        else
          result
        end

      {{:error, exception}, resp, _acc, _state} = result ->
        if retry(resp.request, exception, count) do
          req = put_in(req.private[:req_retry_count], count + 1)
          stream(req, acc, fun, state, next, count + 1)
        else
          result
        end

      {:halt, _resp, _acc, _state} = result ->
        result
    end
  end

  defp retry(req, response_or_exception, count) do
    retry =
      case Map.get(req.options, :retry, :safe_transient) do
        :safe_transient ->
          req.method in [:get, :head] and transient?(response_or_exception)

        :transient ->
          transient?(response_or_exception)

        false ->
          false

        fun when is_function(fun) ->
          apply_retry(fun, req, response_or_exception)

        :safe ->
          IO.warn("setting `retry: :safe` is deprecated in favour of `retry: :safe_transient`")
          req.method in [:get, :head] and transient?(response_or_exception)

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
        if !Req.Request.get_option(req, :retry_delay) do
          do_retry(req, response_or_exception, fn _req, _, _ -> delay end, count)
        else
          raise ArgumentError,
                "expected :retry_delay not to be set when the :retry function is returning `{:delay, milliseconds}`"
        end

      true ->
        do_retry(req, response_or_exception, &get_retry_delay/3, count)

      retry when retry in [false, nil] ->
        false
    end
  end

  defp apply_retry(fun, req, response_or_exception)

  defp apply_retry(fun, _req, response_or_exception) when is_function(fun, 1) do
    IO.warn("`retry: fun/1` has been deprecated in favor of `retry: fun/2`")
    fun.(response_or_exception)
  end

  defp apply_retry(fun, req, response_or_exception) when is_function(fun, 2) do
    fun.(req, response_or_exception)
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

  defp do_retry(req, response_or_exception, delay_getter, retry_count) do
    delay = delay_getter.(req, response_or_exception, retry_count)
    max_retries = Req.Request.get_option(req, :max_retries, 3)
    log_level = Req.Request.get_option(req, :retry_log_level, :warning)

    if retry_count < max_retries do
      log_retry(response_or_exception, retry_count, max_retries, delay, log_level)
      Process.sleep(delay)
      true
    else
      false
    end
  end

  defp get_retry_delay(req, %Req.Response{status: status} = response, retry_count)
       when status in [429, 503] do
    case Req.Request.fetch_option(req, :retry_delay) do
      {:ok, _retry_delay} ->
        calculate_retry_delay(req, retry_count)

      :error ->
        if delay = Req.Response.get_retry_after(response) do
          delay
        else
          calculate_retry_delay(req, retry_count)
        end
    end
  end

  defp get_retry_delay(req, _response, retry_count) do
    calculate_retry_delay(req, retry_count)
  end

  defp calculate_retry_delay(req, retry_count) do
    case Req.Request.get_option(req, :retry_delay, &exp_backoff_with_jitter/1) do
      delay when is_integer(delay) ->
        delay

      fun when is_function(fun, 1) ->
        case fun.(retry_count) do
          delay when is_integer(delay) and delay >= 0 ->
            delay

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

  def legacy_retry({request, response_or_exception}) do
    legacy_retry =
      case Map.get(request.options, :retry, :safe_transient) do
        :safe_transient ->
          request.method in [:get, :head] and transient?(response_or_exception)

        :transient ->
          transient?(response_or_exception)

        false ->
          false

        fun when is_function(fun) ->
          legacy_apply_retry(fun, request, response_or_exception)

        :safe ->
          IO.warn("setting `retry: :safe` is deprecated in favour of `retry: :safe_transient`")
          request.method in [:get, :head] and transient?(response_or_exception)

        :never ->
          IO.warn("setting `retry: :never` is deprecated in favour of `retry: false`")
          false

        other ->
          raise ArgumentError,
                "expected :legacy_retry to be :safe_transient, :transient, false, or a 2-arity function, " <>
                  "got: #{inspect(other)}"
      end

    case legacy_retry do
      {:delay, delay} ->
        if !Req.Request.get_option(request, :retry_delay) do
          legacy_retry(request, response_or_exception, delay)
        else
          raise ArgumentError,
                "expected :retry_delay not to be set when the :legacy_retry function is returning `{:delay, milliseconds}`"
        end

      true ->
        legacy_retry(request, response_or_exception)

      legacy_retry when legacy_retry in [false, nil] ->
        {request, response_or_exception}
    end
  end

  defp legacy_apply_retry(fun, request, response_or_exception)

  defp legacy_apply_retry(fun, _request, response_or_exception) when is_function(fun, 1) do
    IO.warn("`retry: fun/1` has been deprecated in favor of `retry: fun/2`")
    fun.(response_or_exception)
  end

  defp legacy_apply_retry(fun, request, response_or_exception) when is_function(fun, 2) do
    fun.(request, response_or_exception)
  end

  defp legacy_retry(request, response_or_exception, delay_or_nil \\ nil)

  defp legacy_retry(request, response_or_exception, nil) do
    legacy_do_retry(request, response_or_exception, &legacy_get_retry_delay/3)
  end

  defp legacy_retry(request, response_or_exception, delay) when is_integer(delay) do
    legacy_do_retry(request, response_or_exception, fn request, _, _ -> {request, delay} end)
  end

  defp legacy_do_retry(request, response_or_exception, delay_getter) do
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

  defp legacy_get_retry_delay(request, %Req.Response{status: status} = response, retry_count)
       when status in [429, 503] do
    case Req.Request.fetch_option(request, :retry_delay) do
      {:ok, _retry_delay} ->
        legacy_calculate_retry_delay(request, retry_count)

      :error ->
        if delay = Req.Response.get_retry_after(response) do
          {request, delay}
        else
          legacy_calculate_retry_delay(request, retry_count)
        end
    end
  end

  defp legacy_get_retry_delay(request, _response, retry_count) do
    legacy_calculate_retry_delay(request, retry_count)
  end

  defp legacy_calculate_retry_delay(request, retry_count) do
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
end
