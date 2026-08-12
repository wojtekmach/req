defmodule Req.SSE do
  @moduledoc ~S"""
  [Server-sent events][SSE] decoding using `ServerSentEvents`.

  Each event is decoded as a map, e.g. `%{event: "msg", data: "foo"}`. This module is used by
  `Req.Decode` on `text/event-stream`.

  Per the SSE spec, an incomplete event at the end of the stream is discarded.

  [SSE]: https://html.spec.whatwg.org/multipage/server-sent-events.html

  ## Examples

      iex> Req.stream(
      ...>   "https://stream.wikimedia.org/v2/stream/recentchange",
      ...>   nil,
      ...>   fn event, _resp, acc ->
      ...>     %{"type" => type, "title" => title} = JSON.decode!(event.data)
      ...>     IO.puts("#{type}: #{title}")
      ...>     {:cont, acc}
      ...>   end
      ...> )
      # Output: edit: File:Glacier National Park (GeoDIL number - 2068).jpg
      # Output: categorize: Category:Coins of Merovingian dynasty from Gallica
      # ...
  """

  @doc false
  def decode_init(:buffer) do
    {:buffer, ServerSentEvents.Parser.new(), []}
  end

  def decode_init(:stream) do
    {:stream, ServerSentEvents.Parser.new()}
  end

  @doc false
  def decode_chunk({:buffer, parser, events}, data) do
    {new_events, parser} = ServerSentEvents.Parser.parse(parser, data)
    {:ok, nil, {:buffer, parser, Enum.reverse(new_events, events)}}
  end

  def decode_chunk({:stream, parser}, data) do
    {events, parser} = ServerSentEvents.Parser.parse(parser, data)
    {:ok, events, {:stream, parser}}
  end

  # Per the SSE spec, an incomplete event at the end of the stream is discarded.
  @doc false
  def decode_finish({:buffer, _parser, events}) do
    {:ok, Enum.reverse(events)}
  end

  def decode_finish({:stream, _parser}) do
    {:ok, nil}
  end

  @doc false
  def decode_close(_state) do
    :ok
  end
end
