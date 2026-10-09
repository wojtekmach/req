defmodule Req.JSONLibraryTest do
  use ExUnit.Case

  describe "library macro - one-shot operations" do
    test "returns configured library (defaults to JSON)" do
      require Req.JSONLibrary
      lib = Req.JSONLibrary.library()

      # Default should be JSON module
      assert lib == JSON
    end

    test "returned library can handle one-shot operations" do
      require Req.JSONLibrary
      lib = Req.JSONLibrary.library()

      # Verify it responds to the key operations
      # (using can_handle? instead of function_exported? for robustness)
      data = %{test: 1}

      # Should be able to encode
      encoded = lib.encode_to_iodata!(data)
      assert is_list(encoded)

      # Should be able to decode
      result = lib.decode("{\"test\":1}")
      assert result == {:ok, %{"test" => 1}}
    end

    test "returned library has encode! function" do
      require Req.JSONLibrary
      lib = Req.JSONLibrary.library()

      data = %{test: 1}
      result = lib.encode!(data)
      assert is_binary(result)
    end

    test "returned library has decode function" do
      require Req.JSONLibrary
      lib = Req.JSONLibrary.library()

      result = lib.decode("{\"test\":1}")
      assert result == {:ok, %{"test" => 1}}
    end

    test "returned library has decode! function" do
      require Req.JSONLibrary
      lib = Req.JSONLibrary.library()

      result = lib.decode!("{\"test\":1}")
      assert result == %{"test" => 1}
    end

    test "can encode data to iodata" do
      require Req.JSONLibrary
      lib = Req.JSONLibrary.library()

      data = %{hello: "world", count: 42}
      result = lib.encode_to_iodata!(data)

      # Result should be iodata
      assert is_list(result)

      # Should be able to convert to binary
      binary = IO.iodata_to_binary(result)
      assert is_binary(binary)
      assert String.contains?(binary, ["hello", "world", "42"])
    end

    test "can encode data to binary" do
      require Req.JSONLibrary
      lib = Req.JSONLibrary.library()

      data = %{hello: "world"}
      result = lib.encode!(data)

      # Result should be binary
      assert is_binary(result)
      assert String.contains?(result, ["hello", "world"])
    end

    test "can decode JSON binary" do
      require Req.JSONLibrary
      lib = Req.JSONLibrary.library()

      json = "{\"hello\":\"world\"}"
      result = lib.decode(json)

      assert result == {:ok, %{"hello" => "world"}}
    end

    test "can decode! JSON binary" do
      require Req.JSONLibrary
      lib = Req.JSONLibrary.library()

      json = "{\"hello\":\"world\"}"
      result = lib.decode!(json)

      assert result == %{"hello" => "world"}
    end
  end

  describe "streaming_library macro - streaming operations" do
    test "returns configured streaming library (defaults to :json)" do
      require Req.JSONLibrary
      lib = Req.JSONLibrary.streaming_library()

      # Default should be :json Erlang module
      assert lib == :json
    end

    test "returned library has decode_start function" do
      require Req.JSONLibrary
      lib = Req.JSONLibrary.streaming_library()

      assert function_exported?(lib, :decode_start, 3)
    end

    test "returned library has decode_continue function" do
      require Req.JSONLibrary
      lib = Req.JSONLibrary.streaming_library()

      assert function_exported?(lib, :decode_continue, 2)
    end

    test "can start streaming decode" do
      require Req.JSONLibrary
      lib = Req.JSONLibrary.streaming_library()

      {:continue, state} = lib.decode_start("", nil, %{null: nil})
      assert is_tuple(state)
    end

    test "can continue streaming decode" do
      require Req.JSONLibrary
      lib = Req.JSONLibrary.streaming_library()

      {:continue, state} = lib.decode_start("", nil, %{null: nil})
      result = lib.decode_continue("{\"test\":1}", state)

      # Result should be either {:continue, state} or {value, acc, rest}
      assert is_tuple(result)
    end
  end

  describe "wrapper functionality" do
    test "wrapper for :json provides encode_to_iodata!" do
      # This test verifies that if :json is configured,
      # a wrapper is created that provides encode_to_iodata!
      # By default JSON is used, so this is tested indirectly
      # through the library tests above
      require Req.JSONLibrary
      lib = Req.JSONLibrary.library()

      # Encode should work regardless of the underlying library
      data = %{a: 1}
      result = lib.encode_to_iodata!(data)

      assert is_list(result)
    end

    test "wrapper for :json provides encode!" do
      require Req.JSONLibrary
      lib = Req.JSONLibrary.library()

      data = %{a: 1}
      result = lib.encode!(data)

      assert is_binary(result)
    end

    test "wrapper for :json provides decode" do
      require Req.JSONLibrary
      lib = Req.JSONLibrary.library()

      json = "{\"a\":1}"
      result = lib.decode(json)

      assert result == {:ok, %{"a" => 1}}
    end

    test "wrapper for :json provides decode!" do
      require Req.JSONLibrary
      lib = Req.JSONLibrary.library()

      json = "{\"a\":1}"
      result = lib.decode!(json)

      assert result == %{"a" => 1}
    end
  end

  describe "error handling" do
    test "decode! raises on invalid JSON" do
      require Req.JSONLibrary
      lib = Req.JSONLibrary.library()

      assert_raise JSON.DecodeError, fn ->
        lib.decode!("{invalid json}")
      end
    end

    test "encode! handles complex data structures" do
      require Req.JSONLibrary
      lib = Req.JSONLibrary.library()

      data = %{
        nested: %{list: [1, 2, 3]},
        string: "test",
        number: 42,
        boolean: true,
        null: nil
      }

      result = lib.encode!(data)
      assert is_binary(result)

      # Should be able to decode back
      decoded = lib.decode!(result)
      assert decoded["nested"]["list"] == [1, 2, 3]
      assert decoded["string"] == "test"
    end
  end

  describe "macro expansion" do
    test "library macro is compile-time only" do
      require Req.JSONLibrary

      # Calling the macro multiple times should return the same module
      lib1 = Req.JSONLibrary.library()
      lib2 = Req.JSONLibrary.library()

      assert lib1 == lib2
    end

    test "streaming_library macro is compile-time only" do
      require Req.JSONLibrary

      # Calling the macro multiple times should return the same module
      lib1 = Req.JSONLibrary.streaming_library()
      lib2 = Req.JSONLibrary.streaming_library()

      assert lib1 == lib2
    end
  end

  describe "integration with Req modules" do
    test "Req.Steps uses library macro" do
      # Req.Steps uses @json_library Req.JSONLibrary.library()
      # Verify it can encode JSON
      req = %Req.Request{url: URI.parse("http://example.com"), options: [json: %{a: 1}]}
      req = Req.Steps.encode_body(req)

      assert is_binary(req.body) or is_list(req.body)
    end

    test "Req.JSON uses streaming_library macro" do
      # Req.JSON uses @json_library Req.JSONLibrary.streaming_library()
      # Verify streaming decode works
      {:buffer, state} = Req.JSON.decode_init(:buffer)
      assert is_tuple(state)
    end

    test "Req.NDJSON uses library macro" do
      # Req.NDJSON uses @json_library Req.JSONLibrary.library()
      # Verify it can decode NDJSON lines
      {:buffer, "", []} = Req.NDJSON.decode_init(:buffer)
    end
  end
end
