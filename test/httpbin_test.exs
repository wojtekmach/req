defmodule Req.HttpbinTest do
  use ExUnit.Case, async: true

  @moduletag :httpbin

  doctest Req.Steps,
    only: [
      auth: 2,
      put_base_url: 2,
      encode_headers: 1,
      encode_body: 1,
      put_params: 2,
      put_range: 2,
      # run_steps: 2,  #!TODO: make `run_steps/2` testabable
      put_if_modified_since: 2,
      decompress: 1,
      decode_body: 1
    ]
end
