defmodule Req.Decompress do
  @moduledoc """
  Asks the server to return compressed response.

  The response body is decompressed based on the `content-encoding` response header. This step
  is off by default; set `compressed: true` to opt in.

  Supported formats:

  | Format        | Decoder                                         |
  | ------------- | ----------------------------------------------- |
  | gzip, x-gzip  | [`:zlib`]                                       |
  | br            | [`:brotli`] (if [`:brotli`] is installed)       |
  | zstd          | [`:zstd`] (requires Erlang/OTP 28+)             |
  | _other_       | Returns data as is                              |

  This step updates the following headers to reflect the changes:

    * `content-encoding` is removed
    * `content-length` is removed

  > #### Only enable compression for trusted servers {: .info}
  >
  > This step decompresses the whole response body into memory with no size limit, so a small
  > response can expand into many gigabytes. A malicious or compromised server can exploit this
  > to exhaust memory and crash the client (a decompression bomb / denial of service). For this
  > reason compression is off by default; only set `compressed: true` for endpoints you trust.

  ## Request Options

    * `:compressed` - if set to `true`, sets the `accept-encoding` header with compression
      algorithms that Req supports and decompresses the response body. Defaults to `false`.

      This option has no effect when streaming the response body using `into: collectable`.

    * `:raw` - if set to `true`, disables response body decompression. Defaults to `false`.

      Note: setting `raw: true` also disables response body decoding.

  ## Examples

  By default, Req does not ask for a compressed response. Pass `compressed: true` to request one
  and have Req decompress the body, so we get back the decompressed content:

      iex> response = Req.get!("https://elixir-lang.org", compressed: true)
      iex> response.body |> binary_part(0, 15)
      "<!DOCTYPE html>"

  To inspect the raw compressed bytes the server sent, additionally pass `raw: true`, which
  disables decompression. Notice the body now starts with `<<31, 139>>`, the "magic bytes"
  for gzip:

      iex> response = Req.get!("https://elixir-lang.org", compressed: true, raw: true)
      iex> Req.Response.get_header(response, "content-encoding")
      ["gzip"]
      iex> response.body |> binary_part(0, 2)
      <<31, 139>>

  Zstandard is supported out of the box on Erlang/OTP 28+ (via the built-in [`:zstd`] module).
  Brotli is supported if the optional [`:brotli`] package is installed:

      Mix.install([
        :req,
        {:brotli, "~> 0.3.0"}
      ])

      response = Req.get!("https://httpbingo.org/anything", compressed: true)
      response.body["headers"]["Accept-Encoding"]
      #=> ["zstd, br, gzip"]

  [`:zlib`]:   https://www.erlang.org/doc/apps/erts/zlib.html
  [`:brotli`]: https://brotli.hexdocs.pm
  [`:zstd`]:   https://www.erlang.org/doc/apps/stdlib/zstd.html
  """

  require Logger
  require Req.Utils

  def stream(%Req.Request{} = req, acc, fun, state, next) do
    cond do
      req.into != nil ->
        next.(req, acc, fun, state)

      req.options[:compressed] ->
        req = Req.Request.put_header(req, "accept-encoding", supported_accept_encoding())

        if req.options[:raw] == true do
          next.(req, acc, fun, state)
        else
          decompress_stream(req, acc, fun, state, next)
        end

      true ->
        next.(req, acc, fun, state)
    end
  end

  defp decompress_stream(%Req.Request{method: :head} = req, acc, fun, state, next) do
    next.(req, acc, fun, state)
  end

  defp decompress_stream(req, acc, fun, state, next) do
    wrapped = fn
      {:headers, _headers} = event, resp, acc, [nil | state] ->
        formats = formats(resp)
        {formats, rest} = Enum.split_while(formats, &(format(&1) != :unsupported))

        case formats do
          [] ->
            with [format_string | _] <- rest do
              Logger.debug("algorithm #{inspect(format_string)} is not supported")
            end

            {tag, resp, acc, state} = fun.(event, resp, acc, state)
            {tag, resp, acc, [nil | state]}

          formats ->
            resp = fix_headers(resp, formats, rest)
            {tag, resp, acc, state} = fun.(event, resp, acc, state)
            {tag, resp, acc, [{formats, rest} | state]}
        end

      {:data, ""}, resp, acc, [{[format_string | _], _rest} | _] = state
      when is_binary(format_string) ->
        {:cont, resp, acc, state}

      {:data, data}, resp, acc, [{codecs, rest} | state] ->
        codecs =
          case codecs do
            [format_string | _] when is_binary(format_string) ->
              Enum.flat_map(codecs, fn format_string ->
                case format(format_string) do
                  {:ok, mod} -> [{mod, mod.decode_init()}]
                  :identity -> []
                end
              end)

            codecs ->
              codecs
          end

        case decode_chunk(codecs, data) do
          {:ok, nil, codecs} ->
            {:cont, resp, acc, [{codecs, rest} | state]}

          {:ok, data, codecs} ->
            {tag, resp, acc, state} = fun.({:data, data}, resp, acc, state)
            {tag, resp, acc, [{codecs, rest} | state]}

          {:error, exception} ->
            {{:error, exception}, resp, acc, [{codecs, rest} | state]}
        end

      event, resp, acc, [layer | state] ->
        {tag, resp, acc, state} = fun.(event, resp, acc, state)
        {tag, resp, acc, [layer | state]}
    end

    case next.(req, acc, wrapped, [nil | state]) do
      {:ok, resp, acc, [nil | state]} ->
        {:ok, resp, acc, state}

      {:ok, resp, acc, [{[format_string | _], _rest} | state]} when is_binary(format_string) ->
        {:ok, resp, acc, state}

      {:ok, resp, acc, [{codecs, rest} | state]} ->
        case decode_finish(codecs) do
          {:ok, data} ->
            case rest do
              [] ->
                :ok

              [format_string | _] ->
                Logger.debug("algorithm #{inspect(format_string)} is not supported")
            end

            result =
              case data do
                nil ->
                  {:cont, resp, acc, state}

                data ->
                  fun.({:data, data}, resp, acc, state)
              end

            case result do
              {:cont, resp, acc, state} ->
                {:ok, resp, acc, state}

              {:halt, resp, acc, state} ->
                {:halt, resp, acc, state}

              {{:error, exception}, resp, acc, state} ->
                {{:error, exception}, resp, acc, state}
            end

          {:error, exception} ->
            {{:error, exception}, resp, acc, state}
        end

      {tag, resp, acc, [layer | state]} ->
        close_layer(layer)
        {tag, resp, acc, state}
    end
  end

  defp close_layer({codecs, _rest}) do
    close(codecs)
  end

  defp close_layer(_layer) do
    :ok
  end

  defp decode_chunk(codecs, "") do
    {:ok, nil, codecs}
  end

  defp decode_chunk([], data) do
    {:ok, data, []}
  end

  defp decode_chunk([{mod, decoder} | codecs], data) do
    case mod.decode_chunk(decoder, data) do
      {:ok, nil, decoder} ->
        {:ok, nil, [{mod, decoder} | codecs]}

      {:ok, data, decoder} ->
        case decode_chunk(codecs, data) do
          {:ok, data, codecs} ->
            {:ok, data, [{mod, decoder} | codecs]}

          {:error, _exception} = error ->
            error
        end

      {:error, _exception} = error ->
        error
    end
  end

  defp decode_finish([]) do
    {:ok, nil}
  end

  defp decode_finish([{mod, decoder} = codec | codecs]) do
    case mod.decode_finish(decoder) do
      {:ok, nil} ->
        decode_finish(codecs)

      {:ok, data} ->
        case decode_chunk(codecs, data) do
          {:ok, nil, codecs} ->
            decode_finish(codecs)

          {:ok, data, codecs} ->
            case decode_finish(codecs) do
              {:ok, nil} -> {:ok, data}
              {:ok, rest} -> {:ok, data <> rest}
              {:error, _exception} = error -> error
            end

          {:error, _exception} = error ->
            close(codecs)
            error
        end

      {:error, _exception} = error ->
        close([codec | codecs])
        error
    end
  end

  defp fix_headers(resp, codecs, rest) do
    resp =
      case rest do
        [] ->
          Req.Response.delete_header(resp, "content-encoding")

        rest ->
          Req.Response.put_header(resp, "content-encoding", Enum.join(Enum.reverse(rest), ", "))
      end

    if codecs == [] do
      resp
    else
      Req.Response.delete_header(resp, "content-length")
    end
  end

  defp close([{mod, decoder} | codecs]) do
    mod.decode_close(decoder)
    close(codecs)
  end

  defp close(_formats), do: :ok

  defp formats(resp) do
    Req.Response.get_header(resp, "content-encoding")
    |> Enum.flat_map(fn value ->
      value
      |> String.downcase()
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
    end)
    |> Enum.reverse()
  end

  defp format("gzip"), do: {:ok, Req.Gzip}
  defp format("x-gzip"), do: {:ok, Req.Gzip}
  defp format("zstd"), do: {:ok, Req.Zstd}
  defp format("br"), do: {:ok, Req.Brotli}
  defp format("identity"), do: :identity
  defp format(_other), do: :unsupported

  defp supported_accept_encoding do
    value = "gzip"
    value = if Req.Utils.brotli_loaded?(), do: "br, " <> value, else: value
    if Req.Utils.zstd_available?(), do: "zstd, " <> value, else: value
  end

  def compressed(%Req.Request{into: nil} = request) do
    case Req.Request.get_option(request, :compressed, false) do
      true ->
        Req.Request.put_new_header(request, "accept-encoding", legacy_supported_accept_encoding())

      false ->
        request
    end
  end

  def compressed(request) do
    request
  end

  defp legacy_supported_accept_encoding do
    value = "gzip"
    value = if Req.Utils.brotli_loaded?(), do: "br, " <> value, else: value
    if Req.Utils.zstd_available?(), do: "zstd, " <> value, else: value
  end

  def decompress_body({request, %{body: body} = response})
      when request.into != nil or
             body == "" or
             not is_binary(body) do
    {request, response}
  end

  def decompress_body({request, response}) do
    compressed? = Req.Request.get_option(request, :compressed, false) == true
    raw? = request.options[:raw] == true

    if not compressed? or raw? do
      {request, response}
    else
      encoding_headers = Req.Response.get_header(response, "content-encoding")

      case Req.Utils.decompress_with_encoding(encoding_headers, response.body) do
        %Req.DecompressError{} = exception ->
          {request, exception}

        {decompressed_body, unknown_codecs} ->
          response = put_in(response.body, decompressed_body)

          response =
            if unknown_codecs == [] do
              response
              |> Req.Response.delete_header("content-encoding")
              |> Req.Response.delete_header("content-length")
            else
              Req.Response.put_header(
                response,
                "content-encoding",
                Enum.join(unknown_codecs, ", ")
              )
            end

          {request, response}
      end
    end
  end
end
