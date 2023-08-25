defmodule Req.ResponseTest do
  use ExUnit.Case, async: true
  doctest Req.Response, except: [get_header: 2, put_header: 3, delete_header: 2]
end
