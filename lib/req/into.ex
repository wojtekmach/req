defmodule Req.Into do
  @moduledoc false

  @doc false
  def stream(%Req.Request{} = req, acc, fun, state, next) do
    case req.into do
      collectable when collectable not in [nil, :self] and not is_function(collectable, 2) ->
        collect(collectable, req, acc, fun, state, next)

      _ ->
        next.(req, acc, fun, state)
    end
  end

  defp collect(collectable, req, acc, fun, state, next) do
    wrapped = fn
      {:status, 200} = event, resp, acc, [nil | state] ->
        {tag, resp, acc, state} = fun.(event, resp, acc, state)
        {tag, resp, acc, [Collectable.into(collectable) | state]}

      {:data, data}, resp, acc, [{collectable_acc, collector} | state] ->
        collectable_acc = collector.(collectable_acc, {:cont, data})
        {:ok, resp, acc, [{collectable_acc, collector} | state]}

      event, resp, acc, [layer | state] ->
        {tag, resp, acc, state} = fun.(event, resp, acc, state)
        {tag, resp, acc, [layer | state]}
    end

    case next.(req, acc, wrapped, [nil | state]) do
      {:ok, resp, acc, [{collectable_acc, collector} | state]} ->
        body = collector.(collectable_acc, :done)

        case acc do
          %Req.Buffer{} ->
            {:ok, resp, %{acc | decoded: {:ok, body}}, state}

          _ ->
            {:ok, put_in(resp.body, body), acc, state}
        end

      {tag, resp, acc, [{collectable_acc, collector} | state]} ->
        collector.(collectable_acc, :halt)
        {tag, resp, acc, state}

      {tag, resp, acc, [nil | state]} ->
        {tag, resp, acc, state}
    end
  end
end
