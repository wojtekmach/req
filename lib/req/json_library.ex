defmodule Req.JSONLibrary do
  @moduledoc """
  Provides compile-time configuration for the JSON library used by Req.

  This module centralizes JSON library configuration for the Req HTTP client
  using macros for zero-cost abstraction. It intelligently adapts to different
  JSON libraries by checking which functions they export and providing wrappers
  if needed.

  Different contexts require different JSON library APIs:
  - **Streaming context** requires `decode_start/3` and `decode_continue/2`
  - **One-shot context** requires `encode_to_iodata!/1`, `encode!/1`, `decode/1`, `decode!/1`

  ## Configuration

  Configure via `config/config.exs`:

      # For streaming operations (default: :json)
      config :req, :json_streaming_library, :json

      # For one-shot operations (default: JSON)
      config :req, :json_library, JSON

  ## Library Support

  The module automatically adapts to different JSON libraries:

  **Erlang `:json` module:**
  - Provides: `encode/1` (returns iodata), `decode/1`, `decode_start/3`, `decode_continue/2`
  - Missing: `encode_to_iodata!`, `encode!`
  - Solution: Automatically wrapped to provide missing functions

  **Elixir `JSON` module:**
  - Provides: `encode_to_iodata!/1`, `encode!/1`, `decode/1`, `decode!/1`
  - Missing: Streaming functions
  - Works as-is for one-shot operations

  **Jason library:**
  - Provides: `encode!/1`, `encode_to_iodata!/1`, `decode!/1`, `decode/2`
  - Missing: Streaming functions
  - Works as-is for one-shot operations

  **Custom libraries:**
  - Any library can be used, wrapper is created if functions are missing
  - Only requirement: library must export at least `encode/1` and `decode/1`

  ## Usage

  In modules using streaming APIs (like `Req.JSON`):

      defmodule Req.JSON do
        require Req.JSONLibrary
        @json_lib Req.JSONLibrary.streaming_library()

        def decode_init(:buffer) do
          {:continue, state} = @json_lib.decode_start("", nil, %{null: nil})
          {:buffer, state}
        end
      end

  In modules using one-shot APIs (like `Req.Steps`):

      defmodule Req.Steps do
        require Req.JSONLibrary
        @json_lib Req.JSONLibrary.library()

        def encode_body(request) do
          @json_lib.encode_to_iodata!(data)
        end
      end

  The macros expand at compile-time to the configured modules or wrappers,
  providing zero overhead compared to hardcoding the module names.
  """

  @streaming_library Application.compile_env(:req, :json_streaming_library, :json)
  @one_shot_library Application.compile_env(
                      :req,
                      :json_library,
                      Application.compile_env(:phoenix, :json_library, JSON)
                    )

  # Check which functions are exported by the one-shot library
  @has_encode_to_iodata? Code.ensure_loaded?(@one_shot_library) and
                           function_exported?(@one_shot_library, :encode_to_iodata!, 1)
  @has_encode_bang? Code.ensure_loaded?(@one_shot_library) and
                      function_exported?(@one_shot_library, :encode!, 1)

  # If library is missing required functions, create a wrapper
  if not (@has_encode_to_iodata? and @has_encode_bang?) do
    # Determine which encode function is available
    @has_encode? Code.ensure_loaded?(@one_shot_library) and
                   function_exported?(@one_shot_library, :encode, 1)

    wrapper_name = :"Req.JSONLibrary.Wrapper#{:erlang.phash2(@one_shot_library)}"

    defmodule wrapper_name do
      @moduledoc false
      @lib @one_shot_library

      if @has_encode_to_iodata? do
        def encode_to_iodata!(data) do
          @lib.encode_to_iodata!(data)
        end
      else
        if @has_encode? do
          def encode_to_iodata!(data) do
            @lib.encode(data)
          end
        else
          def encode_to_iodata!(_data) do
            raise "JSON library #{inspect(@lib)} does not export encode/1 or encode_to_iodata!/1"
          end
        end
      end

      if @has_encode_bang? do
        def encode!(data) do
          @lib.encode!(data)
        end
      else
        if @has_encode? do
          def encode!(data) do
            @lib.encode(data) |> IO.iodata_to_binary()
          end
        else
          def encode!(_data) do
            raise "JSON library #{inspect(@lib)} does not export encode/1 or encode!/1"
          end
        end
      end

      def decode(binary) do
        @lib.decode(binary)
      end

      def decode!(binary) do
        case @lib.decode(binary) do
          {:ok, value} -> value
          {:error, reason} -> raise "JSON decode error: #{inspect(reason)}"
        end
      end
    end

    @library_for_one_shot wrapper_name
  else
    @library_for_one_shot @one_shot_library
  end

  @doc """
  Macro that returns the configured JSON library for streaming operations at compile-time.

  Streaming operations require `decode_start/3` and `decode_continue/2` functions.

  Defaults to `:json` (Erlang OTP module) if not configured.

  This is a macro, so it expands at compile-time with zero runtime overhead.
  """
  defmacro streaming_library do
    @streaming_library
  end

  @doc """
  Macro that returns the configured JSON library for one-shot operations at compile-time.

  One-shot operations require `encode_to_iodata!/1`, `encode!/1`, `decode/1`, `decode!/1`.

  Defaults to `JSON` (Elixir stdlib module) if not configured.

  If the configured library doesn't have `encode_to_iodata!` and `encode!` functions,
  this macro automatically returns a wrapper that implements them using the library's
  available encoding function (`encode/1` or `encode_to_iodata!/1`).

  This is a macro, so it expands at compile-time with zero runtime overhead.
  """
  defmacro library do
    @library_for_one_shot
  end
end
