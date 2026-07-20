defmodule Req.Decode do
  @moduledoc false

  def decode_body({request, %{body: body} = response})
      when body == "" or not is_binary(body) do
    {request, response}
  end

  def decode_body({request, response}) do
    if request.options[:raw] == true or
         request.options[:decode_body] == false or
         request.options[:decoders] == false or
         Req.Response.get_header(response, "content-encoding") != [] do
      {request, response}
    else
      decoders = build_decoders(request, request.options[:decoders] || [:json, :json_api])

      case decoders[format(request, response)] do
        nil ->
          {request, response}

        codec ->
          run_decoder(request, response, codec)
      end
    end
  end

  @builtin_decoders [:json, :json_api, :zip, :tar, :tgz, :gz, :zst, :csv]

  # Build a map of MIME extension (e.g. "json", "json-api") to codec function, so it can be
  # looked up by the extension detected from the response content-type.
  defp build_decoders(request, decoders) do
    for decoder <- decoders, into: %{} do
      {format, codec} = normalize_decoder(request, decoder)
      {format |> Atom.to_string() |> String.replace("_", "-"), codec}
    end
  end

  defp normalize_decoder(request, format) when is_atom(format) do
    if format in @builtin_decoders do
      {format, builtin_codec(request, format)}
    else
      raise ArgumentError,
            "unknown decoder format: #{inspect(format)}. Built-in formats are: " <>
              Enum.map_join(@builtin_decoders, ", ", &inspect/1) <>
              ". To use a custom format, pass a {format, codec} tuple."
    end
  end

  defp normalize_decoder(request, {format, codec}) when is_atom(format) do
    {format, resolve_codec(request, codec)}
  end

  defp resolve_codec(_request, codec) when is_function(codec, 1) do
    codec
  end

  defp resolve_codec(request, codec) when is_atom(codec) do
    if codec in @builtin_decoders do
      builtin_codec(request, codec)
    else
      # a module exporting decode/1
      &codec.decode/1
    end
  end

  defp builtin_codec(request, format) when format in [:json, :json_api] do
    case Req.Request.fetch_option(request, :decode_json) do
      {:ok, options} ->
        IO.warn(
          "setting `decode_json: options` is deprecated in favour of " <>
            "`decoders: [json: &Jason.decode(&1, options)]`"
        )

        fn body -> Jason.decode(body, options) end

      :error ->
        fn body -> Jason.decode(body) end
    end
  end

  defp builtin_codec(_request, :zip), do: &Req.ZIP.decode/1
  defp builtin_codec(_request, :tar), do: &Req.Tar.decode/1
  defp builtin_codec(_request, :tgz), do: &Req.Tar.decode/1
  defp builtin_codec(_request, :gz), do: &Req.Gzip.decode/1
  defp builtin_codec(_request, :zst), do: &Req.Zstd.decode/1

  defp builtin_codec(_request, :csv) do
    fn body -> {:ok, NimbleCSV.RFC4180.parse_string(body, skip_headers: false)} end
  end

  defp run_decoder(request, response, codec) do
    case codec.(response.body) do
      {:ok, decoded} ->
        {request, put_in(response.body, decoded)}

      {:error, %{__exception__: true} = exception} ->
        {request, exception}

      {:error, reason} ->
        {request, %RuntimeError{message: "decoding response body failed: #{inspect(reason)}"}}
    end
  end

  defp format(request, response) do
    path = request.url.path || ""

    case Req.Response.get_header(response, "content-type") do
      [content_type | _] ->
        case extensions(content_type, path) do
          [ext | _] -> ext
          [] -> nil
        end

      [] ->
        case extensions("application/octet-stream", path) do
          [ext | _] -> ext
          [] -> nil
        end
    end
  end

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
