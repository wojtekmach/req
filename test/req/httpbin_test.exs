defmodule Req.HttpbinTest do
  use ExUnit.Case

  @moduletag :httpbin

  setup do
    original_gl = Process.group_leader()
    {:ok, capture_gl} = StringIO.open("")
    Process.group_leader(self(), capture_gl)

    on_exit(fn ->
      Process.group_leader(self(), original_gl)
    end)
  end

  doctest Req.Steps,
    only: [
      auth: 2,
      put_base_url: 2,
      encode_headers: 1,
      encode_body: 1,
      put_params: 2,
      put_range: 2,
      run_steps: 2,
      put_if_modified_since: 2,
      decompress: 1,
      decode_body: 1
    ]
end
