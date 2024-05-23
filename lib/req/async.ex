defmodule Req.Async do
  @moduledoc """
  TODO
  """

  @derive {Inspect, only: []}
  defstruct [:ref, :stream_fun, :cancel_fun]

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
