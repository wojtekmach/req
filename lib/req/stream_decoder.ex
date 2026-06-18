defmodule Req.StreamDecoder do
  @moduledoc false

  @typep state() :: any()

  @typep element() :: any()

  @callback decode(binary(), opts :: keyword()) :: {:ok, [element()]} | {:error, Exception.t()}

  @callback decode_init(opts :: keyword()) :: state()

  @callback decode_chunk(binary(), state()) ::
              {:ok, [element()], state()} | {:error, Exception.t(), state()}

  @callback decode_finish(state()) ::
              {:ok, [element()], state()} | {:error, Exception.t(), state()}

  @optional_callbacks decode_init: 1, decode_chunk: 2, decode_finish: 1
end
