defmodule Req.Response.Async do
  @moduledoc """
  Asynchronous response body.

  This is the `response.body` when making a request with `into: :self`, that is,
  streaming response body chunks to the current process mailbox.

  This struct implements the `Enumerale` protocol where each element is a body chunk received
  from the current process mailbox. HTTP Trailer fields are ignored.

  **Note:** this feature is currently experimental and it may change in future releases.

  ## Examples

      iex> resp = Req.get!("https://reqbin.org/ndjson?delay=1000", into: :self)
      iex> resp.body
      #Req.Response.Async<...>
      iex> Enum.each(resp.body, &IO.puts/1)
      # {"id":0}
      # {"id":1}
      # {"id":2}
      :ok
  """

  @derive {Inspect, only: []}
  defstruct [:pid, :ref, :stream_fun, :cancel_fun]

  defimpl Enumerable do
    def count(_async), do: {:error, __MODULE__}

    def member?(_async, _value), do: {:error, __MODULE__}

    def slice(_async), do: {:error, __MODULE__}

    def reduce(async, {:halt, acc}, _fun) do
      cancel(async)
      {:halted, acc}
    end

    def reduce(async, {:suspend, acc}, fun) do
      {:suspended, acc, &reduce(async, &1, fun)}
    end

    def reduce(async, {:cont, acc}, fun) do
      if async.pid != self() do
        raise "expected to read body chunk in the process #{inspect(async.pid)} which made the request, got: #{inspect(self())}"
      end

      receive do
        message ->
          case async.stream_fun.(async.ref, message) do
            {:ok, [data: data]} ->
              result =
                try do
                  fun.(data, acc)
                rescue
                  e ->
                    cancel(async)
                    reraise e, __STACKTRACE__
                end

              reduce(async, result, fun)

            {:ok, [:done]} ->
              {:done, acc}

            {:ok, [trailers: _trailers]} ->
              reduce(async, {:cont, acc}, fun)

            {:error, e} ->
              raise e
          end
      end
    end

    defp cancel(async) do
      async.cancel_fun.(async.ref)
    end
  end
end
