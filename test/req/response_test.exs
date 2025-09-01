defmodule Req.ResponseTest do
  use ExUnit.Case, async: true
  doctest Req.Response, except: [get_header: 2, delete_header: 2]

  describe "get_retry_after/1" do
    test "parses integer retry-after values" do
      response = Req.Response.new(headers: [{"retry-after", "5"}])
      assert Req.Response.get_retry_after(response) == 5000
    end

    test "parses decimal retry-after values" do
      response = Req.Response.new(headers: [{"retry-after", "2.0"}])
      assert Req.Response.get_retry_after(response) == 2000
    end

    test "handles edge cases" do
      response = Req.Response.new(headers: [{"retry-after", "0.0"}])
      assert Req.Response.get_retry_after(response) == 0
    end

    test "returns nil when retry-after header is not present" do
      response = Req.Response.new()
      assert Req.Response.get_retry_after(response) == nil
    end

    test "parses HTTP date retry-after values" do
      future_date = DateTime.utc_now() |> DateTime.add(60, :second)
      http_date = Req.Utils.format_http_date(future_date)
      response = Req.Response.new(headers: [{"retry-after", http_date}])

      result = Req.Response.get_retry_after(response)
      assert_in_delta result, 60000, 1000
    end
  end
end
