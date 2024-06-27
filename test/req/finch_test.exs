defmodule Req.FinchTest do
  use ExUnit.Case, async: true

  describe "pool_options" do
    test "defaults" do
      assert Req.Finch.pool_options([]) ==
               [
                 protocols: [:http1]
               ]
    end

    test "ipv6" do
      assert Req.Finch.pool_options(inet6: true) ==
               [
                 protocols: [:http1],
                 conn_opts: [transport_opts: [inet6: true]]
               ]
    end

    test "connect_options protocols" do
      assert Req.Finch.pool_options(connect_options: [protocols: [:http2]]) ==
               [
                 protocols: [:http2]
               ]
    end

    test "connect_options timeout" do
      assert Req.Finch.pool_options(connect_options: [timeout: 0]) ==
               [
                 protocols: [:http1],
                 conn_opts: [transport_opts: [timeout: 0]]
               ]
    end

    test "connect_options transport_opts" do
      assert Req.Finch.pool_options(connect_options: [transport_opts: [cacerts: []]]) ==
               [
                 protocols: [:http1],
                 conn_opts: [transport_opts: [cacerts: []]]
               ]
    end

    test "connect_options transport_opts + timeout + ipv6" do
      assert Req.Finch.pool_options(
               connect_options: [timeout: 0, transport_opts: [cacerts: []]],
               inet6: true
             ) ==
               [
                 protocols: [:http1],
                 conn_opts: [transport_opts: [timeout: 0, inet6: true, cacerts: []]]
               ]
    end
  end
end
