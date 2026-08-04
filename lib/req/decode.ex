defmodule Req.Decode do
  @moduledoc """
  Decodes response body based on the detected format.

  To decode other formats, or to add support for custom ones, use the `:decoders` option.

  ## Built-in decoders

  | Format               | Decoder                                       | Enabled | Streaming |
  | -------------------- | --------------------------------------------- | ------- | --------- |
  | `:json`, `:json_api` | `Req.JSON`                                    | ✓       |           |
  | `:zip`               | `Req.ZIP`                                     |         |           |
  | `:tar`, `:tgz`       | `Req.Tar`                                     |         |           |
  | `:gz`                | [`:zlib`](`:zlib`)                            |         | ✓         |
  | `:zst`               | [`:zstd`](`:zstd`) (requires Erlang/OTP 28+)  |         | ✓         |
  | `:csv`               | `NimbleCSV.RFC4180` (requires [nimble_csv])   |         |           |

  The format is determined by the response `content-type` header. See `MIME` for registering
  content-type/format mapping.

  > #### Decompression Bombs {: .warning}
  >
  > The archive and compression decoders (`:zip`, `:tar`, `:tgz`, `:gz`, and `:zst`) decompress
  > the whole response body into memory with no size limit, so a small response can expand to
  > many gigabytes. For this reason they are **not** enabled by default; only opt into them via
  > the `:decoders` option for endpoints you trust.

  ## Request Options

    * `:decoders` - the list of decoders to use. Defaults to
      `[:json, :json_api]`.

      Each element is either:

        * a format (atom) handled by a [built-in decoder](#module-built-in-decoders),
          e.g. `:json` or `:zip`;

        * a `{format, codec}` tuple, where `format` is an atom and `codec` is one of:

            * another format (atom), to reuse a built-in decoder, e.g. `{:json5, :json}`;

            * a module exporting `decode/1` that returns `{:ok, term}` or `{:error, exception}`.

              On response body streaming (`Req.stream/4`), the module must also export
              `decode_init/0`, `decode_chunk/2`, `decode_finish/1`, and `decode_close/1`:
              `decode_chunk(state, data)` returns `{:ok, output, state}` where `output` is a
              value or list of values, each delivered as its own data event (`nil` for none),
              and `decode_finish(state)` returns `{:ok, output}` for the remaining tail.
              Return the input unchanged from `decode_chunk` if the format cannot be
              decoded incrementally;

            * a 1-arity function that returns `{:ok, term}` or `{:error, exception}`.

      Setting `:decoders` replaces the default, so include `:json` if you still want JSON decoded:

          # handles json, zip, and tar:
          Req.new(decoders: [:json, :zip, :tar])

      Set `:decoders` to `false` to disable all decoding, including JSON. A custom decoder:

          Req.get!(url, decoders: [ics: &{:ok, ICal.from_ics(&1)}])

    * `:decode_body` - if set to `false`, disables automatic response body decoding.
      Defaults to `true`.

    * `:raw` - if set to `true`, disables response body decoding. Defaults to `false`.

      Note: setting `raw: true` also disables response body decompression.

  ## Examples

  Decode JSON:

      iex> response = Req.get!("https://httpbingo.org/json")
      ...> response.body["slideshow"]["title"]
      "Sample Slide Show"

  Decode a ZIP archive (opt-in):

      iex> response = Req.get!("https://example.com/archive.zip", decoders: [:zip])
      ...> response.body["file.txt"]
      "contents"

  [nimble_csv]: https://hex.pm/packages/nimble_csv
  [server_sent_events]: https://hex.pm/packages/server_sent_events
  """

  @default [
    json: Req.JSON,
    json_api: Req.JSON
  ]

  @decoders [
    json: Req.JSON,
    json_api: Req.JSON,
    gz: Req.Gzip,
    zip: Req.ZIP,
    tar: Req.Tar,
    tgz: Req.Tar,
    zst: Req.Zstd,
    csv: Req.CSV
  ]

  def stream(%Req.Request{} = req, acc, fun, state, next) do
    if req.options[:raw] == true or req.options[:decode_body] == false or
         req.options[:decoders] == false do
      next.(req, acc, fun, state)
    else
      decode_stream(req, acc, fun, state, next)
    end
  end

  defp decode_stream(%Req.Request{method: :head} = req, acc, fun, state, next) do
    next.(req, acc, fun, state)
  end

  defp decode_stream(req, acc, fun, state, next) do
    wrapped = fn
      {:data, data}, resp, acc, [nil | state] ->
        decoder =
          case decoder(resp) do
            nil ->
              false

            fun when is_function(fun, 1) ->
              fun

            mod when is_atom(mod) ->
              cond do
                match?(%Req.Buffer{}, acc) ->
                  decode_init(mod, :buffer)

                req.into == nil ->
                  decode_init(mod, :stream)

                true ->
                  false
              end
          end

        decode_data(decoder, data, resp, acc, state, fun)

      {:data, data}, resp, acc, [decoder | state] ->
        decode_data(decoder, data, resp, acc, state, fun)

      event, resp, acc, [decoder | state] ->
        {tag, resp, acc, state} = fun.(event, resp, acc, state)
        {tag, resp, acc, [decoder | state]}
    end

    case next.(req, acc, wrapped, [nil | state]) do
      {:ok, resp, acc, [decoder | state]} when decoder in [nil, false] ->
        {:ok, resp, acc, state}

      {:ok, resp, %Req.Buffer{} = buffer, [{mod, decoder} | state]} ->
        case mod.decode_finish(decoder) do
          {:ok, decoded} ->
            {:ok, resp, %{buffer | decoded: {:ok, decoded}}, state}

          {:error, err} ->
            {{:error, err}, resp, buffer, state}
        end

      {:ok, resp, acc, [{mod, decoder} | state]} ->
        case mod.decode_finish(decoder) do
          {:ok, output} ->
            case emit(List.wrap(output), resp, acc, state, fun) do
              {:cont, resp, acc, state} ->
                {:ok, resp, acc, state}

              {:halt, resp, acc, state} ->
                {:halt, resp, acc, state}

              {{:error, err}, resp, acc, state} ->
                {{:error, err}, resp, acc, state}
            end

          {:error, err} ->
            close({mod, decoder})
            {{:error, err}, resp, acc, state}
        end

      {:ok, resp, %Req.Buffer{} = buffer, [decode_fun | state]} when is_function(decode_fun, 1) ->
        case decode_fun.(Req.Buffer.to_binary(buffer)) do
          {:ok, decoded} ->
            {:ok, resp, %{buffer | decoded: {:ok, decoded}}, state}

          {:error, %{__exception__: true} = err} ->
            {{:error, err}, resp, buffer, state}

          {:error, reason} ->
            err = RuntimeError.exception("decoding response body failed: #{inspect(reason)}")
            {{:error, err}, resp, buffer, state}
        end

      {tag, resp, acc, [layer | state]} ->
        close(layer)
        {tag, resp, acc, state}
    end
  end

  defp decode_data(false, data, resp, acc, state, fun) do
    {tag, resp, acc, state} = fun.({:data, data}, resp, acc, state)
    {tag, resp, acc, [false | state]}
  end

  defp decode_data(decoder, data, resp, acc, state, fun) do
    case decode(decoder, data) do
      {:ok, output, decoder} ->
        {tag, resp, acc, state} = emit(List.wrap(output), resp, acc, state, fun)
        {tag, resp, acc, [decoder | state]}

      {:error, err} ->
        {{:error, err}, resp, acc, [decoder | state]}
    end
  end

  defp decode({decoder_mod, decoder_state}, data) do
    case decoder_mod.decode_chunk(decoder_state, data) do
      {:ok, decoded, decoder_state} ->
        {:ok, decoded, {decoder_mod, decoder_state}}

      {:error, err} ->
        {:error, err}
    end
  end

  defp decode(decoder_fun, data) when is_function(decoder_fun, 1) do
    {:ok, data, decoder_fun}
  end

  defp close({mod, decoder}), do: mod.decode_close(decoder)
  defp close(_layer), do: :ok

  defp emit([], resp, acc, state, _fun) do
    {:cont, resp, acc, state}
  end

  defp emit([data | rest], resp, acc, state, fun) do
    case fun.({:data, data}, resp, acc, state) do
      {:cont, resp, acc, state} ->
        emit(rest, resp, acc, state, fun)

      result ->
        result
    end
  end

  defp decoder(%Req.Response{status: status})
       when status in 100..199 or status in [204, 205, 304] do
    nil
  end

  defp decoder(resp) do
    if Req.Response.get_header(resp, "content-encoding") == [] do
      path = resp.request.url.path || ""

      content_type =
        case Req.Response.get_header(resp, "content-type") do
          [content_type | _] -> content_type
          [] -> "application/octet-stream"
        end

      extensions = extensions(content_type, path)

      decoders =
        Enum.map(resp.request.options[:decoders] || @default, fn
          format when is_atom(format) ->
            decoder =
              format_module(format) ||
                raise ArgumentError, "unknown decoder: #{inspect(format)}"

            {format, decoder}

          {format, decoder} when is_atom(format) and is_atom(decoder) ->
            {format, format_module(decoder) || decoder}

          {format, fun} when is_atom(format) and is_function(fun, 1) ->
            {format, fun}

          other ->
            raise ArgumentError,
                  "expected decoders: format or {format, decoder}, got: #{inspect(other)}"
        end)

      Enum.find_value(decoders, fn {format_atom, decoder} ->
        format_string = format_atom |> Atom.to_string() |> String.replace("_", "-")
        format_string in extensions && decoder
      end)
    end
  end

  defp decode_init(mod, mode) do
    {mod, mod.decode_init(mode)}
  rescue
    e in UndefinedFunctionError ->
      if function_exported?(mod, :decode, 1) do
        IO.warn(
          "passing {format, mod} is deprecated in favour of {format, &mod.decode/1}. " <>
            "In future releases there will be a public module decoder contract."
        )

        &mod.decode/1
      else
        reraise e, __STACKTRACE__
      end
  end

  for {format, module} <- @decoders do
    defp format_module(unquote(format)), do: unquote(module)
  end

  defp format_module(_other), do: nil

  defp extensions("application/octet-stream" <> _, path) do
    if tgz?(path) do
      ["tgz"]
    else
      path |> MIME.from_path() |> MIME.extensions()
    end
  end

  defp extensions("application/" <> subtype, path) when subtype in ~w(gzip x-gzip) do
    if tgz?(path) do
      ["tgz"]
    else
      ["gz"]
    end
  end

  # TODO: remove once `text/event-stream` is registered in MIME (elixir-plug/mime#88).
  defp extensions("text/event-stream" <> _, _path) do
    ["sse"]
  end

  defp extensions("application/x-ndjson" <> _, _path) do
    ["ndjson"]
  end

  defp extensions("application/ndjson" <> _, _path) do
    ["ndjson"]
  end

  defp extensions(content_type, _path) do
    MIME.extensions(content_type)
  end

  defp tgz?(path) do
    case Path.extname(path) do
      ".tgz" -> true
      ".gz" -> String.ends_with?(path, ".tar.gz")
      _ -> false
    end
  end
end
