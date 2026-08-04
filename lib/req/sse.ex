defmodule Req.SSE do
  @moduledoc """
  [Server-sent events][SSE] decoding using `ServerSentEvents`.

  Each event is decoded as a map, e.g. `%{event: "msg", data: "foo"}`. This module is used by
  `Req.Decode` on `text/event-stream`. With `Req.stream/4`, each event is delivered as its own
  data event; per the SSE spec, an incomplete event at the end of the stream is discarded.

  [SSE]: https://html.spec.whatwg.org/multipage/server-sent-events.html
  """

  @doc false
  def decode_init do
    ServerSentEvents.Parser.new()
  end

  @doc false
  def decode_chunk(parser, data) do
    {events, parser} = ServerSentEvents.Parser.parse(parser, data)
    {:ok, events, parser}
  end

  # Per the SSE spec, an incomplete event at the end of the stream is discarded.
  @doc false
  def decode_finish(_parser) do
    {:ok, []}
  end

  @doc false
  def decode_close(_state) do
    :ok
  end

  @doc false
  def decode(binary) do
    {:ok, events, _parser} = decode_chunk(decode_init(), binary)
    {:ok, events}
  end
end
