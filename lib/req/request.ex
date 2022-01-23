defmodule Req.Request do
  @moduledoc ~S"""
  The request pipeline struct.

  Struct fields:

    * `:method` - the HTTP request method

    * `:url` - the HTTP request URL

    * `:headers` - the HTTP request headers

    * `:body` - the HTTP request body

    * `:adapter` - a request step that makes the actual HTTP request

    * `:unix_socket` - if set, connect through the given UNIX domain socket

    * `:halted` - whether the request pipeline is halted. See `halt/1`

    * `:request_steps` - the list of request steps

    * `:response_steps` - the list of response steps

    * `:error_steps` - the list of error steps

    * `:private` - a map reserved for libraries and frameworks to use.
      Prefix the keys with the name of your project to avoid any future
      conflicts. Only accepts `t:atom/0` keys.

  ## Steps

  Under the hood, Req works by passing a [`%Req.Request{}`](`Req.Request`) struct through a series of steps.

  Request steps are used to refine the data that will be sent to the server.

  After making the actual HTTP request, we'll either get a HTTP response or an error.
  The request, along with the response or error, will go through response or
  error steps, respectively.

  Nothing is actually executed until we run the pipeline with `Req.Request.run/1`.

  ### Request steps

  A request step is a function that accepts a `request` and returns one of the following:

    * A `request`

    * A `{request, response_or_error}` tuple. In that case no further request steps are executed
      and the return value goes through response or error steps

  Examples:

      def put_default_headers(request) do
        update_in(request.headers, &[{"user-agent", "req"} | &1])
      end

      def read_from_cache(request) do
        case ResponseCache.fetch(request) do
          {:ok, response} -> {request, response}
          :error -> request
        end
      end

  ### Response and error steps

  A response step is a function that accepts a `{request, response}` tuple and returns one of the
  following:

    * A `{request, response}` tuple

    * A `{request, exception}` tuple. In that case, no further response steps are executed but the
      exception goes through error steps

  Similarly, an error step is a function that accepts a `{request, exception}` tuple and returns one
  of the following:

    * A `{request, exception}` tuple

    * A `{request, response}` tuple. In that case, no further error steps are executed but the
      response goes through response steps

  Examples:

      def decode({request, response}) do
        case List.keyfind(response.headers, "content-type", 0) do
          {_, "application/json" <> _} ->
            {request, update_in(response.body, &Jason.decode!/1)}

          _ ->
            {request, response}
        end
      end

      def log_error({request, exception}) do
        Logger.error(["#{request.method} #{request.uri}: ", Exception.message(exception)])
        {request, exception}
      end

  ### Halting

  Any step can call `Req.Request.halt/1` to halt the pipeline. This will prevent any further steps
  from being invoked.

  Examples:

      def circuit_breaker(request) do
        if CircuitBreaker.open?() do
          {Req.Request.halt(request), RuntimeError.exception("circuit breaker is open")}
        else
          request
        end
      end
  """

  defstruct [
    :method,
    :url,
    headers: [],
    body: "",
    adapter: {Req.Steps, :run_finch, []},
    unix_socket: nil,
    halted: false,
    request_steps: [],
    response_steps: [],
    error_steps: [],
    private: %{},
    location_trusted: false
  ]

  @doc """
  Sets the request adapter.

  Adapter is a request step that is making the actual HTTP request. See
  `Req.Request.build/3` for more information.

  """
  def put_adapter(request, adapter) do
    %{request | adapter: adapter}
  end

  @doc """
  Gets the value for a specific private `key`.
  """
  def get_private(request, key, default \\ nil) when is_atom(key) do
    Map.get(request.private, key, default)
  end

  @doc """
  Assigns a private `key` to `value`.
  """
  def put_private(request, key, value) when is_atom(key) do
    put_in(request.private[key], value)
  end

  @doc """
  Halts the request pipeline preventing any further steps from executing.
  """
  def halt(request) do
    %{request | halted: true}
  end

  @doc """
  Builds a request pipeline.

  ## Options

    * `:header` - request headers, defaults to `[]`

    * `:body` - request body, defaults to `""`

    * `:adapter` - adapter to use to make the actual HTTP request. Adapters are functions
    specified like any other request step, but the adapter function is the last step
    executed in the request pipeline. Defaults to calling `Req.Steps.run_finch/1`.

    * `:finch` - Finch pool to use, defaults to `Req.Finch` which is automatically started
      by the application. See `Finch` module documentation for more information on starting pools.

    * `:finch_options` - Options passed down to Finch when making the request, defaults to `[]`.
      See `Finch.request/3` for more information.

  """
  def build(method, url, options \\ []) do
    %Req.Request{
      method: method,
      url: URI.parse(url),
      headers: Keyword.get(options, :headers, []),
      body: Keyword.get(options, :body, ""),
      unix_socket: Keyword.get(options, :unix_socket),
      adapter: Keyword.get(options, :adapter, {Req.Steps, :run_finch, []}),
      private: %{
        req_finch:
          {Keyword.get(options, :finch, Req.Finch), Keyword.get(options, :finch_options, [])}
      }
    }
  end

  @doc """
  Appends request steps.
  """
  def append_request_steps(request, steps) do
    update_in(request.request_steps, &(&1 ++ steps))
  end

  @doc """
  Prepends request steps.
  """
  def prepend_request_steps(request, steps) do
    update_in(request.request_steps, &(steps ++ &1))
  end

  @doc """
  Appends response steps.
  """
  def append_response_steps(request, steps) do
    update_in(request.response_steps, &(&1 ++ steps))
  end

  @doc """
  Prepends response steps.
  """
  def prepend_response_steps(request, steps) do
    update_in(request.response_steps, &(steps ++ &1))
  end

  @doc """
  Appends error steps.
  """
  def append_error_steps(request, steps) do
    update_in(request.error_steps, &(&1 ++ steps))
  end

  @doc """
  Prepends error steps.
  """
  def prepend_error_steps(request, steps) do
    update_in(request.error_steps, &(steps ++ &1))
  end

  @doc """
  Runs a request pipeline.

  Returns `{:ok, response}` or `{:error, exception}`.
  """
  def run(request) do
    steps = request.request_steps ++ [request.adapter]

    Enum.reduce_while(steps, request, fn step, acc ->
      case run_step(step, acc) do
        %Req.Request{} = request ->
          {:cont, request}

        {%Req.Request{halted: true}, response_or_exception} ->
          {:halt, result(response_or_exception)}

        {request, %Req.Response{} = response} ->
          {:halt, run_response(request, response)}

        {request, %{__exception__: true} = exception} ->
          {:halt, run_error(request, exception)}
      end
    end)
  end

  @doc """
  Runs a request pipeline and returns a response or raises an error.

  See `run/1` for more information.
  """
  def run!(request) do
    case run(request) do
      {:ok, response} -> response
      {:error, exception} -> raise exception
    end
  end

  defp run_response(request, response) do
    steps = request.response_steps

    {_request, response_or_exception} =
      Enum.reduce_while(steps, {request, response}, fn step, {request, response} ->
        case run_step(step, {request, response}) do
          {%Req.Request{halted: true} = request, response_or_exception} ->
            {:halt, {request, response_or_exception}}

          {request, %Req.Response{} = response} ->
            {:cont, {request, response}}

          {request, %{__exception__: true} = exception} ->
            {:halt, run_error(request, exception)}
        end
      end)

    result(response_or_exception)
  end

  defp run_error(request, exception) do
    steps = request.error_steps

    {_request, response_or_exception} =
      Enum.reduce_while(steps, {request, exception}, fn step, {request, exception} ->
        case run_step(step, {request, exception}) do
          {%Req.Request{halted: true} = request, response_or_exception} ->
            {:halt, {request, response_or_exception}}

          {request, %{__exception__: true} = exception} ->
            {:cont, {request, exception}}

          {request, %Req.Response{} = response} ->
            {:halt, run_response(request, response)}
        end
      end)

    result(response_or_exception)
  end

  @doc false
  def run_step(step, state)

  def run_step({module, function, args}, state) do
    apply(module, function, [state | args])
  end

  def run_step({module, options}, state) do
    apply(module, :run, [state | [options]])
  end

  def run_step(module, state) when is_atom(module) do
    apply(module, :run, [state, []])
  end

  def run_step(func, state) when is_function(func, 1) do
    func.(state)
  end

  defp result(%Req.Response{} = response) do
    {:ok, response}
  end

  defp result(%{__exception__: true} = exception) do
    {:error, exception}
  end
end
