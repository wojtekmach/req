defmodule Req.TarTest do
  use Req.Case, async: true

  doctest Req.Tar,
    tags: [:integration],
    inspect_opts: [pretty: true, limit: 2]
end
