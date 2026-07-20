defmodule Req.Decompress do
  @moduledoc false

  require Req.Utils

  def compressed(%Req.Request{into: nil} = request) do
    case Req.Request.get_option(request, :compressed, false) do
      true ->
        Req.Request.put_new_header(request, "accept-encoding", supported_accept_encoding())

      false ->
        request
    end
  end

  def compressed(request) do
    request
  end

  defp supported_accept_encoding do
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
