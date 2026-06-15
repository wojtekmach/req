defmodule Req.StreamDecoder do
  @moduledoc false

  @typep state() :: any()

  @typep element() :: any()

  # Decodes a buffered body. Not used by decoders that only ever run on streamed
  # bodies, e.g. Req.DecompressStream, whose buffered counterpart lives in Req.Steps.
  @callback decode(binary()) :: {:ok, [element()]} | {:error, Exception.t()}

  @optional_callbacks decode: 1

  @callback stream_start(Req.Response.t()) :: state()

  @callback stream_chunk(binary(), state()) ::
              {:ok, [element()], state()} | {:error, Exception.t(), state()}

  @callback stream_finish(state()) ::
              {:ok, [element()], state()} | {:error, Exception.t(), state()}
end
