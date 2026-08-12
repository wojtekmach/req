defmodule Req.Adapter do
  @moduledoc """
  The adapter contract.

  By default Req uses `Finch` (via `Req.Finch`) and supports arbitrary adapters implementing this
  behaviour.

  Req adapters are closely related to step wrappers, see
  ["Steps & Step Wrappers" section](`Req.Request#module-steps-step-wrappers`) in `Req.Request` module documentation for
  more information.
  """

  @callback stream(req, acc, fun, state) ::
              {:ok, resp, acc, state}
              | {:halt, resp, acc, state}
              | {{:error, err}, resp, acc, state}
            when req: Req.Request.t(),
                 resp: Req.Response.t(),
                 err: Exception.t(),
                 acc: term(),
                 fun: (event, resp, acc, state ->
                         {:ok, resp, acc, state}
                         | {:halt, resp, acc, state}
                         | {{:error, err}, resp, acc, state}),
                 state: term(),
                 event:
                   {:status, non_neg_integer()}
                   | {:headers, [{binary(), binary()}]}
                   | {:data, binary()}
                   | {:trailers, [{binary(), binary()}]}
end
