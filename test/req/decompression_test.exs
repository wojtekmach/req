defmodule Req.DecompressionTest do
  use ExUnit.Case, async: true
  @moduletag :live

  describe "brotli decompression" do
    test "loads pages in the wild" do
      for url <- [
            "https://wordpress.org",
            "https://crafted.ie",
            "https://www.tiktok.app",
            "https://www.sleepeasy.app"
          ] do
        assert %Req.Response{body: body} = Req.get!(url)
        assert String.valid?(body)
      end
    end
  end
end
