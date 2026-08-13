defmodule Req.ZIPTest do
  use Req.Case, async: true

  doctest Req.ZIP,
    tags: [:integration],
    inspect_opts: [pretty: true, limit: 2]
end
