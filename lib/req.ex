defmodule Req do
  @moduledoc """
  """

  defstruct [
    :request,
    request_steps: [],
    response_steps: [],
    error_steps: [],
    private: %{}
  ]

  ## High-level API

  @doc """
  Makes a GET request.
  """
  def get!(url, opts \\ []) do
    case request(:get, url, opts) do
      {:ok, response} -> response
      {:error, error} -> raise error
    end
  end

  @doc """
  Makes an HTTP request.
  """
  def request(method, url, opts \\ []) do
    method
    |> build(url, opts)
    |> run()
  end

  ## Low-level API

  @doc """
  Builds a Req pipeline.
  """
  def build(method, url, opts \\ []) do
    body = Keyword.get(opts, :body, "")
    headers = Keyword.get(opts, :headers, [])
    request = Finch.build(method, url, headers, body)

    %Req{
      request: request
    }
  end

  @doc """
  Runs a pipeline.
  """
  def run(state) do
    result =
      Enum.reduce_while(state.request_steps, state.request, fn step, acc ->
        case run(step, acc, state) do
          %Finch.Request{} = request ->
            {:cont, request}

          %Finch.Response{} = response ->
            {:halt, {:response, response}}

          %{__exception__: true} = exception ->
            {:halt, {:error, exception}}

          {:halt, result} ->
            {:halt, {:halt, result}}
        end
      end)

    case result do
      %Finch.Request{} = request ->
        run_request(request, state)

      {:response, response} ->
        run_response(response, state)

      {:error, exception} ->
        run_error(exception, state)

      {:halt, result} ->
        halt(result)
    end
  end

  @doc """
  Executes a request and runs its result through a pipeline.
  """
  def run_request(request, state) do
    case Finch.request(request, Req.Finch) do
      {:ok, response} ->
        run_response(response, state)

      {:error, exception} ->
        run_error(exception, state)
    end
  end

  @doc """
  Runs a response through a pipeline.
  """
  def run_response(response, state) do
    Enum.reduce_while(state.response_steps, {:ok, response}, fn step, {:ok, acc} ->
      case run(step, acc, state) do
        %Finch.Response{} = response ->
          {:cont, {:ok, response}}

        %{__exception__: true} = exception ->
          {:halt, run_error(exception, state)}

        {:halt, result} ->
          {:halt, halt(result)}
      end
    end)
  end

  @doc """
  Runs an exception through a pipeline.
  """
  def run_error(exception, state) do
    Enum.reduce_while(state.error_steps, {:error, exception}, fn step, {:error, acc} ->
      case run(step, acc, state) do
        %{__exception__: true} = exception ->
          {:cont, {:error, exception}}

        %Finch.Response{} = response ->
          {:halt, run_response(response, state)}

        {:halt, result} ->
          {:halt, halt(result)}
      end
    end)
  end

  defp run(fun, request_or_response_or_exception, _state) when is_function(fun, 1) do
    fun.(request_or_response_or_exception)
  end

  defp run(fun, request_or_response_or_exception, state) when is_function(fun, 2) do
    fun.(request_or_response_or_exception, state)
  end

  @doc """
  Assigns a new private `key` and `value`.
  """
  def put_private(state, key, value) do
    update_in(state.private, &Map.put(&1, key, value))
  end

  @doc """
  Gets the value for a specific private `key`.
  """
  def get_private(state, key, default \\ nil) do
    Map.get(state.private, key, default)
  end

  defp halt(%Finch.Response{} = response) do
    {:ok, response}
  end

  defp halt(%{__exception__: true} = exception) do
    {:error, exception}
  end

  ## Request steps

  def default_headers(request) do
    put_new_header(request, "user-agent", "req/0.1.0-dev")
  end

  ## Error steps

  @doc """
  Retries a request in face of errors.

  This function can be used as either or both response and error step. It retries a request that
  resulted in:

    * a response with status 5xx

    * an exception

  """
  def retry(%{status: status} = response, _state) when status < 500 do
    response
  end

  def retry(response_or_exception, state) do
    max_attempts = 2
    attempt = get_private(state, :retry_attempt, 0)

    if attempt < max_attempts do
      state = put_private(state, :retry_attempt, attempt + 1)
      {:halt, state.request |> run_request(state) |> elem(1)}
    else
      response_or_exception
    end
  end

  ## Utilities

  def add_request_steps(state, steps) do
    update_in(state.request_steps, &(&1 ++ steps))
  end

  def add_response_steps(state, steps) do
    update_in(state.response_steps, &(&1 ++ steps))
  end

  def add_error_steps(state, steps) do
    update_in(state.error_steps, &(&1 ++ steps))
  end

  defp put_new_header(struct, name, value) do
    if Enum.any?(struct.headers, fn {key, _} -> String.downcase(key) == name end) do
      struct
    else
      update_in(struct.headers, &[{name, value} | &1])
    end
  end
end
