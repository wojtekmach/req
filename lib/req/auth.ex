defmodule Req.Auth do
  @moduledoc """
  Sets request authentication.

  For HTTP Digest authentication, when the response is HTTP 401 with a `www-authenticate`
  header, this step calculates the `authorization: Digest ...` header and makes another
  request.

  ## Request Options

    * `:auth` - sets the `authorization` header:

        * `string` - sets to this value;

        * `{:basic, userinfo}` - uses Basic HTTP authentication;

        * `{:digest, userinfo}` - uses Digest HTTP authentication;

        * `{:bearer, token}` - uses Bearer HTTP authentication;

        * `:netrc` - load credentials from `.netrc` at path specified in `NETRC` environment variable.
          If `NETRC` is not set, load `.netrc` in user's home directory;

        * `{:netrc, path}` - load credentials from `path`

        * `fn -> {:bearer, "eyJ0eXAi..." } end` - a 0-arity function that returns one of the aforementioned types.

        * `{mod, fun, args}` - an MFArgs tuple that returns one of the aforementioned types.

  ## Examples

      iex> Req.get!("https://httpbingo.org/basic-auth/foo/bar", auth: {:basic, "foo:foo"}).status
      401
      iex> Req.get!("https://httpbingo.org/basic-auth/foo/bar", auth: {:basic, "foo:bar"}).status
      200
      iex> Req.get!("https://httpbingo.org/basic-auth/foo/bar", auth: fn -> {:basic, "foo:bar"} end).status
      200
      iex> Req.get!("https://httpbingo.org/basic-auth/foo/bar", auth: {Authentication, :fetch_token, []}).status
      200

      iex> Req.get!("https://httpbingo.org/digest-auth/auth/user/pass", auth: {:digest, "user:pass"}).status
      200

      iex> Req.get!("https://httpbingo.org/bearer", auth: {:bearer, ""}).status
      401
      iex> Req.get!("https://httpbingo.org/bearer", auth: {:bearer, "foo"}).status
      200
      iex> Req.get!("https://httpbingo.org/bearer", auth: fn -> {:bearer, "foo"} end).status
      200

      iex> System.put_env("NETRC", "./test/my_netrc")
      iex> Req.get!("https://httpbingo.org/basic-auth/foo/bar", auth: :netrc).status
      200

      iex> Req.get!("https://httpbingo.org/basic-auth/foo/bar", auth: {:netrc, "./test/my_netrc"}).status
      200
      iex> Req.get!("https://httpbingo.org/basic-auth/foo/bar", auth: fn -> {:netrc, "./test/my_netrc"} end).status
      200
  """

  require Logger

  @doc false
  def stream(%Req.Request{} = req, acc, fun, state, next) do
    case next.(auth(req), acc, fun, state) do
      {:ok, resp, _acc, _state} = result ->
        case http_digest(resp.request, resp) do
          {:digest, req} ->
            next.(req, acc, fun, state)

          false ->
            result
        end

      result ->
        result
    end
  end

  defp auth(request) do
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

  defp http_digest(request, %Req.Response{status: 401} = response) do
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
      request =
        request
        |> Req.Request.delete_option(:auth)
        |> Req.Request.put_header("authorization", auth_header_value)

      {:digest, request}
    else
      {:error, {:unsupported_digest_algorithm, algorithm}} ->
        Logger.warning("unsupported digest algorithm sent by the server: #{algorithm}")
        false

      _ ->
        false
    end
  end

  defp http_digest(_request, _response) do
    false
  end
end
