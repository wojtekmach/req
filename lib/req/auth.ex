defmodule Req.Auth do
  @moduledoc false

  require Logger

  def auth(request) do
    auth(request, request.options[:auth])
  end

  defp auth(request, nil) do
    request
  end

  defp auth(request, authorization) when is_binary(authorization) do
    Req.Request.put_header(request, "authorization", authorization)
  end

  defp auth(request, {:basic, userinfo}) when is_binary(userinfo) do
    Req.Request.put_header(request, "authorization", "Basic " <> Base.encode64(userinfo))
  end

  defp auth(request, {:bearer, token}) when is_binary(token) do
    Req.Request.put_header(request, "authorization", "Bearer " <> token)
  end

  defp auth(request, {:digest, userinfo}) when is_binary(userinfo) do
    request
  end

  defp auth(request, fun) when is_function(fun, 0) do
    value = fun.()

    if is_function(value, 0) do
      raise ArgumentError, "setting `auth: fn -> ... end` should not return another function"
    end

    auth(request, value)
  end

  defp auth(request, {mod, fun, args}) when is_atom(mod) and is_atom(fun) and is_list(args) do
    value = apply(mod, fun, args)

    auth(request, value)
  end

  defp auth(request, :netrc) do
    path = System.get_env("NETRC") || Path.join(System.user_home!(), ".netrc")
    authenticate_with_netrc(request, path)
  end

  defp auth(request, {:netrc, path}) do
    authenticate_with_netrc(request, path)
  end

  defp auth(request, {username, password}) when is_binary(username) and is_binary(password) do
    IO.warn(
      "setting `auth: {username, password}` is deprecated in favour of `auth: {:basic, userinfo}`"
    )

    Req.Request.put_header(
      request,
      "authorization",
      "Basic " <> Base.encode64("#{username}:#{password}")
    )
  end

  defp authenticate_with_netrc(request, path_or_device) do
    case Map.fetch(Req.Utils.load_netrc(path_or_device), request.url.host) do
      {:ok, {username, password}} ->
        auth(request, {:basic, "#{username}:#{password}"})

      :error ->
        request
    end
  end

  def handle_http_digest({request, %Req.Response{status: 401} = response}) do
    with {:digest, userinfo} <- request.options[:auth],
         [username, password] <- String.split(userinfo, ":", parts: 2),
         ["Digest " <> _ = challenge_header | _] <-
           Req.Response.get_header(response, "www-authenticate"),
         {:ok, auth_header_value} <-
           Req.Utils.http_digest_auth(
             challenge_header,
             username,
             password,
             request.method || :get,
             request.url.path || "/"
           ) do
      request
      |> Req.Request.delete_option(:auth)
      |> Req.Request.put_header("authorization", auth_header_value)
      |> Req.Request.run_request()
    else
      {:error, {:unsupported_digest_algorithm, algorithm}} ->
        Logger.warning("unsupported digest algorithm sent by the server: #{algorithm}")
        {request, response}

      _ ->
        {request, response}
    end
  end

  def handle_http_digest(other) do
    other
  end
end
