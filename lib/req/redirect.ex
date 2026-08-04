defmodule Req.Redirect do
  @moduledoc """
  Follows redirects.

  The original request method may be changed to GET depending on the status code:

  | Code          | Method handling    |
  | ------------- | ------------------ |
  | 301, 302, 303 | Changed to GET     |
  | 307, 308      | Method not changed |

  ## Request Options

    * `:redirect` - if set to `false`, disables automatic response redirects.
      Defaults to `true`.

    * `:redirect_trusted` - by default, authorization credentials are only sent
      on redirects with the same host, scheme and port. If `:redirect_trusted` is set
      to `true`, credentials will be sent to any host.

    * `:redirect_log_level` - the log level to emit redirect logs at. Can also be set
      to `false` to disable logging these messages. Defaults to `:debug`.

    * `:max_redirects` - the maximum number of redirects, defaults to `10`. If the
      limit is reached, a `Req.TooManyRedirectsError` exception is returned.

  ## Examples

      iex> Req.get!("http://api.github.com").status
      # 23:24:11.670 [debug] redirecting to https://api.github.com/
      200

      iex> Req.get!("https://httpbingo.org/redirect/4", max_redirects: 3)
      # 23:07:59.570 [debug] redirecting to /relative-redirect/3
      # 23:08:00.068 [debug] redirecting to /relative-redirect/2
      # 23:08:00.206 [debug] redirecting to /relative-redirect/1
      ** (RuntimeError) too many redirects (3)

      iex> Req.get!("http://api.github.com", redirect_log_level: false)
      200

      iex> Req.get!("http://api.github.com", redirect_log_level: :error)
      # 23:24:11.670 [error]  redirecting to https://api.github.com/
      200
  """

  require Logger

  def stream(%Req.Request{} = req, acc, fun, state, next) do
    if redirect?(req) do
      wrapped = fn
        {:headers, _headers} = event, resp, acc, state
        when resp.status in [301, 302, 303, 307, 308] ->
          if redirect_resp?(resp) do
            {:halt, resp, acc, state}
          else
            fun.(event, resp, acc, state)
          end

        event, resp, acc, state ->
          fun.(event, resp, acc, state)
      end

      stream(req, acc, wrapped, state, next, _count = 0)
    else
      next.(req, acc, fun, state)
    end
  end

  defp stream(req, acc, fun, state, next, count) do
    case next.(req, acc, fun, state) do
      {:halt, resp, acc, state} = result ->
        if redirect_resp?(resp) do
          max_redirects = Req.Request.get_option(req, :max_redirects, 10)

          if count < max_redirects do
            [location | _] = Req.Response.get_header(resp, "location")
            req = build_redirect_request(req, resp, location)
            req = put_in(req.private[:req_redirect_count], count + 1)
            stream(req, acc, fun, state, next, count + 1)
          else
            exception = %Req.TooManyRedirectsError{max_redirects: max_redirects}
            {{:error, exception}, resp, acc, state}
          end
        else
          result
        end

      result ->
        result
    end
  end

  defp redirect?(req) do
    case Req.Request.fetch_option(req, :follow_redirects) do
      {:ok, redirect?} ->
        IO.warn(":follow_redirects option has been renamed to :redirect")
        redirect?

      :error ->
        Req.Request.get_option(req, :redirect, true)
    end
  end

  defp redirect_resp?(resp) do
    resp.status in [301, 302, 303, 307, 308] and
      Req.Response.get_header(resp, "location") != []
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
      response.request.url
      |> URI.merge(URI.parse(location))
      |> normalize_redirect_uri()

    request
    # assume put_params step already run so remove :params option so it's not applied again
    |> Req.Request.delete_option(:params)
    |> remove_credentials_if_untrusted(redirect_trusted, response.request.url, location_url)
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

  defp remove_credentials_if_untrusted(request, true, _, _), do: request

  defp remove_credentials_if_untrusted(request, _, url, location_url) do
    if {location_url.host, location_url.scheme, location_url.port} ==
         {url.host, url.scheme, url.port} do
      request
    else
      request
      |> Req.Request.delete_header("authorization")
      |> Req.Request.delete_option(:auth)
    end
  end

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
end
