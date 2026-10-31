defmodule Req.JSONLibrary do
  @moduledoc """
  Provides compile-time configuration for the JSON library used by Req.

  This module centralizes JSON library configuration for the Req HTTP client
  using macros for zero-cost abstraction. It intelligently adapts to different
  JSON libraries by checking which functions they export and providing wrappers
  if needed.

  Different contexts require different JSON library APIs, and these are
  library requirements:

  - **Streaming context** requires `decode_start/3` and `decode_continue/2`
  - **One-shot context** requires `encode_to_iodata!/1`, `encode!/1`, and
    `decode/1`. `decode!/1` is treated as an optional convenience fallback when
    a library exposes it but not `decode/1`.

  ## Configuration

  Configure via `config/config.exs`:

      # For one-shot and streamingoperations (default: :json)
      config :req, :json_library, JSON

  ## Library Support

  The module automatically adapts to different JSON libraries:

  **Erlang `:json` module:**
  - Provides: `encode/1` (returns iodata), `decode/1`, `decode_start/3`, `decode_continue/2`
  - Missing: `encode_to_iodata!`, `encode!`
  - Solution: Automatically wrapped to provide missing functions

  **Glazer library (`Glazer.JSON`) **
  - Provides: `encode!/1`, `encode_to_iodata!/1`, `decode!/1`, `decode/2`,
    `decode_start/3`, `decode_continue/2`
  - Works as-is for one-shot and streaming operations

  **Elixir `JSON` module:**
  - Provides: `encode_to_iodata!/1`, `encode!/1`, `decode/1`, `decode!/1`
  - Missing: Streaming functions
  - Works as-is for one-shot operations and maps to :json for streaming operations

  **Jason library:**
  - Provides: `encode!/1`, `encode_to_iodata!/1`, `decode!/1`, `decode/2`
  - Missing: Streaming functions
  - Works as-is for one-shot operations, and maps to :json for streaming operations

  **Custom libraries:**
  - Any library can be used, wrapper is created if functions are missing
  - See library requirements for one-shot and streaming contexts.

  ## Usage

  In modules using streaming APIs (like `Req.JSON`):

      defmodule Req.JSON do
        require Req.JSONLibrary
        @json_lib Req.JSONLibrary.library()

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

  @json_library Application.compile_env(
                      :req,
                      :json_library,
                      Application.compile_env(:phoenix, :json_library, JSON)
                    )

  # Check which functions are exported by the one-shot library
  @has_encode_to_iodata_bang? Code.ensure_loaded?(@json_library) and
                           function_exported?(@json_library, :encode_to_iodata!, 1)
  @has_encode_bang? Code.ensure_loaded?(@json_library) and
                      function_exported?(@json_library, :encode!, 1)

  @has_decode? Code.ensure_loaded?(@json_library) and
                      function_exported?(@json_library, :decode, 1)

  @has_decode_start? Code.ensure_loaded?(@json_library) and
                      function_exported?(@json_library, :decode_start, 3)

  @has_decode_continue? Code.ensure_loaded?(@json_library) and
                      function_exported?(@json_library, :decode_continue, 2)

  @has_json_decode_start? Code.ensure_loaded?(:json) and
                          function_exported?(:json, :decode_start, 3)

  @has_json_decode_continue? Code.ensure_loaded?(:json) and
                            function_exported?(:json, :decode_continue, 2)

  # If library is missing required functions, create a wrapper.
  # Req itself only requires `decode/1` for one-shot decoding; `decode!/1` is
  # supported as an optional fallback when present.
  if not (@has_encode_to_iodata_bang? and @has_encode_bang? and
          (@has_decode? or @has_decode_bang?) and
          @has_decode_start? and @has_decode_continue?) do
    # Determine which encode function is available
    @has_encode? Code.ensure_loaded?(@json_library) and
                   function_exported?(@json_library, :encode, 1)

    @has_decode_bang? Code.ensure_loaded?(@json_library) and
                   function_exported?(@json_library, :decode!, 1)

    wrapper_name = :"Req.JSONLibrary.Wrapper#{:erlang.phash2(@json_library)}"

    wrapper_ast =
      quote bind_quoted: [
        lib: @json_library,
        has_encode_to_iodata_bang?: @has_encode_to_iodata_bang?,
        has_encode_bang?: @has_encode_bang?,
        has_encode?: @has_encode?,
        has_decode?: @has_decode?,
        has_decode_bang?: @has_decode_bang?,
        has_decode_start?: @has_decode_start?,
        has_decode_continue?: @has_decode_continue?,
        has_json_decode_start?: @has_json_decode_start?,
        has_json_decode_continue?: @has_json_decode_continue?
      ] do
        @moduledoc false
        @lib lib
        @has_encode_to_iodata_bang? has_encode_to_iodata_bang?
        @has_encode_bang? has_encode_bang?
        @has_encode? has_encode?
        @has_decode? has_decode?
        @has_decode_bang? has_decode_bang?
        @has_decode_start? has_decode_start?
        @has_decode_continue? has_decode_continue?
        @has_json_decode_start? has_json_decode_start?
        @has_json_decode_continue? has_json_decode_continue?

        if @has_encode_to_iodata_bang? do
          def encode_to_iodata!(data), do: @lib.encode_to_iodata!(data)
        else
          if @has_encode? do
            def encode_to_iodata!(data), do: @lib.encode(data)
          else
            def encode_to_iodata!(_data) do
              raise "JSON library #{inspect(@lib)} does not export encode/1 or encode_to_iodata!/1"
            end
          end
        end

        if @has_encode_bang? do
          def encode!(data), do: @lib.encode!(data)
        else
          if @has_encode? do
            def encode!(data) do
              case @lib.encode(data) do
                {:ok, bin} when is_binary(bin) -> bin
                {:ok, bin} when is_list(bin) -> IO.iodata_to_binary(bin)
                bin when is_binary(bin) -> bin
                {:error, reason} -> raise "JSON encode error: #{inspect(reason)}"
              end
            end
          else
            def encode!(_data) do
              raise "JSON library #{inspect(@lib)} does not export encode/1 or encode!/1"
            end
          end
        end

        if @has_decode? do
          def decode(binary), do: @lib.decode(binary)

          if @has_decode_bang? do
            def decode!(binary), do: @lib.decode!(binary)
          else
            def decode!(binary) do
              case @lib.decode(binary) do
                {:ok, term} -> term
                {:error, reason} -> raise JSON.DecodeError, message: inspect(reason)
              end
            end
          end
        else
          if @has_decode_bang? do
            def decode(binary) do
              {:ok, @lib.decode!(binary)}
            rescue
              e in JSON.DecodeError ->
                {:error, e.message}
              e ->
                {:error, inspect(e)}
            end

            def decode!(binary), do: @lib.decode!(binary)
          else
            def decode(_binary) do
              raise "JSON library #{inspect(@lib)} does not export decode/1"
            end

            def decode!(_binary) do
              raise "JSON library #{inspect(@lib)} does not export decode!/1"
            end
          end
        end

        if @has_decode_start? do
          def decode_start(binary, acc, opts), do: @lib.decode_start(binary, acc, opts)
        else
          if @has_json_decode_start? do
            def decode_start(binary, acc, opts), do: :json.decode_start(binary, acc, opts)
          else
            def decode_start(_binary, _acc, _opts) do
              raise "JSON library #{inspect(@lib)} does not export decode_start/3"
            end
          end
        end

        if @has_decode_continue? do
          def decode_continue(data, state), do: @lib.decode_continue(data, state)
        else
          if @has_json_decode_continue? do
            def decode_continue(data, state), do: :json.decode_continue(data, state)
          else
            def decode_continue(_data, _state) do
              raise "JSON library #{inspect(@lib)} does not export decode_continue/2"
            end
          end
        end
      end

    Module.create(wrapper_name, wrapper_ast, Macro.Env.location(__ENV__))

    @library_for_json wrapper_name
  else
    @library_for_json @json_library
  end

  @doc """
  Macro that returns the configured JSON library for one-shot and streaming operations
  at compile-time.

  One-shot operations require `encode_to_iodata!/1`, `encode!/1`, and `decode/1`.
  `decode!/1` is treated as an optional convenience fallback instead of a
  required Req dependency.

  Streaming operations require `decode_start/3` and `decode_continue/2` functions.

  Defaults to `:json` (Erlang OTP module) if not configured.

  If the configured library doesn't have `encode_to_iodata!` and `encode!` functions,
  this macro automatically returns a wrapper that implements them using the library's
  available encoding function (`encode/1` or `encode_to_iodata!/1`).

  This is a macro, so it expands at compile-time with zero runtime overhead.
  """
  defmacro library do
    @library_for_json
  end
end
