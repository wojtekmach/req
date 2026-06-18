defmodule Req.EventStream do
  @moduledoc false

  @behaviour Req.StreamDecoder

  @impl true
  def decode(binary, _opts \\ []) when is_binary(binary) do
    {:ok, events, parser} = decode_chunk(binary, decode_init([]))
    {:ok, rest, _parser} = decode_finish(parser)
    {:ok, events ++ rest}
  end

  @doc false
  def stream(binary) when is_binary(binary) do
    Stream.transform(
      [binary],
      fn -> decode_init([]) end,
      fn data, state ->
        {:ok, events, state} = decode_chunk(data, state)
        {events, state}
      end,
      fn state ->
        {:ok, events, state} = decode_finish(state)
        {events, state}
      end,
      fn _state -> :ok end
    )
  end

  @impl true
  def decode_init(_opts) do
    ServerSentEvents.Parser.new()
  end

  @impl true
  def decode_chunk(data, parser) do
    {events, parser} = ServerSentEvents.Parser.parse(parser, data)
    {:ok, events, parser}
  end

  # Per the SSE spec, an incomplete event at the end of the stream is discarded.
  @impl true
  def decode_finish(parser) do
    {:ok, [], parser}
  end
end
