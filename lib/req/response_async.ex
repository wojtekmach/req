defmodule Req.Response.Async do
  @moduledoc """
  Asynchronous response body.

  This is the `response.body` when making a request with `into: :self`, that is,
  streaming response body chunks to the current process mailbox.

  This struct implements the `Enumerale` protocol where each element is a body chunk received
  from the current process mailbox. Note: HTTP Trailer fields are ignored.

  ## Examples

      iex> resp = Req.get!("http://httpbin.org/stream/2", into: :self)
      iex> resp.body
      #Req.Response.Async<...>
      iex> Enum.map(resp.body, & &1["id"])
      [0, 1]
  """

  @derive {Inspect, only: []}
  defstruct [:pid, :ref, :stream_fun, :cancel_fun]

  defimpl Enumerable do
    def count(_async), do: {:error, __MODULE__}

    def member?(_async, _value), do: {:error, __MODULE__}

    def slice(_async), do: {:error, __MODULE__}

    def reduce(_async, {:halt, acc}, _fun) do
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
              reduce(async, fun.(data, acc), fun)

            {:ok, [:done]} ->
              {:done, acc}

            {:ok, [trailers: _trailers]} ->
              reduce(async, {:cont, acc}, fun)

            {:error, e} ->
              raise e
          end
      end
    end
  end
end
