defmodule Req.Redirect do
  @moduledoc false

  require Logger

  def redirect({request, response}) do
    redirect? =
      case Req.Request.fetch_option(request, :follow_redirects) do
        {:ok, redirect?} ->
          IO.warn(":follow_redirects option has been renamed to :redirect")
          redirect?

        :error ->
          Req.Request.get_option(request, :redirect, true)
      end

    with true <- redirect? && response.status in [301, 302, 303, 307, 308],
         [location | _] <- Req.Response.get_header(response, "location") do
      max_redirects = Req.Request.get_option(request, :max_redirects, 10)
      redirect_count = Req.Request.get_private(request, :req_redirect_count, 0)

      if redirect_count < max_redirects do
        with %Req.Response.Async{} <- response.body do
          Req.cancel_async_response(response)
        end

        request =
          request
          |> build_redirect_request(response, location)
          |> Req.Request.put_private(:req_redirect_count, redirect_count + 1)

        {request, response_or_exception} = Req.Request.run_request(request)
        Req.Request.halt(request, response_or_exception)
      else
        Req.Request.halt(request, %Req.TooManyRedirectsError{max_redirects: max_redirects})
      end
    else
      _ ->
        {request, response}
    end
  end

  defp build_redirect_request(request, response, location) do
    log_level = Req.Request.get_option(request, :redirect_log_level, :debug)
    location = strip_redirect_userinfo(location)
    log_redirect(log_level, location)

    redirect_trusted =
      case Req.Request.fetch_option(request, :location_trusted) do
        {:ok, trusted} ->
          IO.warn(":location_trusted option has been renamed to :redirect_trusted")
          trusted

        :error ->
          request.options[:redirect_trusted]
      end

    location_url =
      request.url
      |> URI.merge(URI.parse(location))
      |> normalize_redirect_uri()

    request
    # assume put_params step already run so remove :params option so it's not applied again
    |> Req.Request.delete_option(:params)
    |> remove_credentials_if_untrusted(redirect_trusted, location_url)
    |> change_post_to_get(response.status)
    |> Map.replace!(:url, location_url)
  end

  # Userinfo in a redirect location is dropped (and never converted to auth) to avoid silently
  # sending credentials supplied by the redirecting server. Done before logging so it isn't leaked.
  defp strip_redirect_userinfo(location) do
    case URI.parse(location) do
      %URI{userinfo: nil} ->
        location

      %URI{} = uri ->
        Logger.warning("stripping userinfo from redirect location")
        URI.to_string(%{uri | userinfo: nil})
    end
  end

  defp log_redirect(false, _location), do: :ok

  defp log_redirect(level, location) do
    Logger.log(level, ["redirecting to ", location])
  end

  defp normalize_redirect_uri(%URI{scheme: "http", port: nil} = uri), do: %{uri | port: 80}
  defp normalize_redirect_uri(%URI{scheme: "https", port: nil} = uri), do: %{uri | port: 443}
  defp normalize_redirect_uri(%URI{} = uri), do: uri

  # https://www.rfc-editor.org/rfc/rfc9110#name-301-moved-permanently and 302:
  #
  # > Note: For historical reasons, a user agent MAY change the request method from
  # > POST to GET for the subsequent request.
  #
  # And my understanding is essentially same applies for 303.
  # Also see https://everything.curl.dev/http/redirects
  defp change_post_to_get(%{method: :post} = request, status) when status in 301..303 do
    request
    |> Map.merge(%{method: :get, body: nil})
    |> Req.Request.drop_options([:json, :form, :form_multipart])
    |> Req.Request.delete_header("content-type")
    |> Req.Request.delete_header("content-length")
  end

  defp change_post_to_get(request, _status) do
    request
  end

  defp remove_credentials_if_untrusted(request, true, _), do: request

  defp remove_credentials_if_untrusted(request, _, location_url) do
    if {location_url.host, location_url.scheme, location_url.port} ==
         {request.url.host, request.url.scheme, request.url.port} do
      request
    else
      request
      |> Req.Request.delete_header("authorization")
      |> Req.Request.delete_option(:auth)
    end
  end
end
