defmodule Req.EventStream do
  # Decodes `text/event-stream` using the :server_sent_events package.
  @moduledoc false

  @behaviour Req.StreamDecoder

  # Buffered decoding, so the module can also be used as a `:decoders` codec.
  @impl true
  def decode(binary) when is_binary(binary) do
    {:ok, events, parser} = stream_chunk(binary, stream_start(nil))
    {:ok, rest, _parser} = stream_finish(parser)
    {:ok, events ++ rest}
  end

  @doc false
  def stream(binary) when is_binary(binary) do
    Stream.transform(
      [binary],
      fn -> stream_start(nil) end,
      fn data, state ->
        {:ok, events, state} = stream_chunk(data, state)
        {events, state}
      end,
      fn state ->
        {:ok, events, state} = stream_finish(state)
        {events, state}
      end,
      fn _state -> :ok end
    )
  end

  @impl true
  def stream_start(_resp) do
    ServerSentEvents.Parser.new()
  end

  @impl true
  def stream_chunk(data, parser) do
    {events, parser} = ServerSentEvents.Parser.parse(parser, data)
    {:ok, events, parser}
  end

  # Per the SSE spec, an incomplete event at the end of the stream is discarded.
  @impl true
  def stream_finish(parser) do
    {:ok, [], parser}
  end
end
