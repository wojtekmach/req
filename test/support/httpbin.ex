defmodule HTTPBin do
  use Plug.Router

  @max_body 100_000_000

  plug :match
  plug :read_raw_body

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: JSON,
    body_reader: {__MODULE__, :read_cached_body, []},
    length: @max_body

  plug :dispatch

  # httpbin's `data` field needs the raw body, which Plug.Parsers discards, so we
  # read it once up front and let the parsers reuse it. Multipart bodies are
  # streamed by Plug.Parsers instead (and don't need `data`).
  def read_raw_body(conn, _opts) do
    case get_req_header(conn, "content-type") |> List.first() do
      "multipart/form-data" <> _ ->
        conn

      _ ->
        {:ok, body, conn} = Plug.Conn.read_body(conn, length: @max_body)
        assign(conn, :raw_body, body)
    end
  end

  def read_cached_body(conn, opts) do
    case conn.assigns[:raw_body] do
      nil -> Plug.Conn.read_body(conn, opts)
      body -> {:ok, body, conn}
    end
  end

  get "/json" do
    body = """
    {
      "slideshow": {
        "author": "Yours Truly",
        "date": "date of publication",
        "slides": [
          {
            "title": "Wake up to WonderWidgets!",
            "type": "all"
          },
          {
            "items": [
              "Why <em>WonderWidgets</em> are great",
              "Who <em>buys</em> WonderWidgets"
            ],
            "title": "Overview",
            "type": "all"
          }
        ],
        "title": "Sample Slide Show"
      }
    }
    """

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  get "/user-agent" do
    json(conn, 200, %{"user-agent" => get_req_header(conn, "user-agent") |> List.first()})
  end

  get "/headers" do
    json(conn, 200, %{"headers" => headers(conn)})
  end

  get "/ip" do
    json(conn, 200, %{"origin" => origin(conn)})
  end

  get "/get" do
    render(conn, ~w(url args headers origin))
  end

  post "/post" do
    render(conn, ~w(url args form data origin headers files json))
  end

  put "/put" do
    render(conn, ~w(url args form data origin headers files json))
  end

  patch "/patch" do
    render(conn, ~w(url args form data origin headers files json))
  end

  delete "/delete" do
    render(conn, ~w(url args form data origin headers files json))
  end

  match "/anything" do
    render(conn, ~w(url args headers origin method form data files json))
  end

  match "/anything/*_rest" do
    render(conn, ~w(url args headers origin method form data files json))
  end

  match "/status/:code" do
    send_resp(conn, String.to_integer(code), "")
  end

  get "/stream/:n" do
    n = min(String.to_integer(n), 100)

    base = %{
      "url" => url(conn),
      "args" => fetch_query_params(conn).query_params,
      "headers" => headers(conn),
      "origin" => origin(conn)
    }

    conn =
      conn
      |> put_resp_content_type("application/json")
      |> send_chunked(200)

    Enum.reduce(0..(n - 1), conn, fn i, conn ->
      {:ok, conn} = chunk(conn, JSON.encode!(Map.put(base, "id", i)) <> "\n")
      conn
    end)
  end

  get "/basic-auth/:user/:passwd" do
    with ["Basic " <> encoded] <- get_req_header(conn, "authorization"),
         {:ok, decoded} <- Base.decode64(encoded),
         [^user, ^passwd] <- String.split(decoded, ":", parts: 2) do
      json(conn, 200, %{"authenticated" => true, "user" => user})
    else
      _ ->
        conn
        |> put_resp_header("www-authenticate", ~s|Basic realm="Fake Realm"|)
        |> send_resp(401, "")
    end
  end

  get "/bearer" do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] ->
        json(conn, 200, %{"authenticated" => true, "token" => token})

      _ ->
        conn
        |> put_resp_header("www-authenticate", "Bearer")
        |> send_resp(401, "")
    end
  end

  get "/digest-auth/:qop/:user/:passwd" do
    case get_req_header(conn, "authorization") do
      ["Digest " <> params] ->
        credentials = parse_digest(params)

        if digest_response(credentials, conn.method, passwd) == credentials["response"] do
          json(conn, 200, %{"authenticated" => true, "user" => user})
        else
          digest_challenge(conn, qop)
        end

      _ ->
        digest_challenge(conn, qop)
    end
  end

  get "/range/:numbytes" do
    numbytes = String.to_integer(numbytes)

    case get_req_header(conn, "range") do
      ["bytes=" <> spec] ->
        [first, last] =
          spec |> String.split("-", parts: 2) |> Enum.map(&String.to_integer/1)

        conn
        |> put_resp_content_type("application/octet-stream")
        |> put_resp_header("accept-ranges", "bytes")
        |> put_resp_header("content-range", "bytes #{first}-#{last}/#{numbytes}")
        |> send_resp(206, range_bytes(first, last))

      _ ->
        conn
        |> put_resp_content_type("application/octet-stream")
        |> put_resp_header("accept-ranges", "bytes")
        |> send_resp(200, range_bytes(0, numbytes - 1))
    end
  end

  match "/delay/:n" do
    n = min(String.to_integer(n), 10)
    Process.sleep(n * 1000)
    render(conn, ~w(url args form data origin headers files))
  end

  get "/redirect/:n" do
    n = String.to_integer(n)
    location = if n <= 1, do: "/get", else: "/redirect/#{n - 1}"

    conn
    |> put_resp_header("location", location)
    |> send_resp(302, "")
  end

  get "/gzip" do
    body =
      JSON.encode!(%{
        "origin" => origin(conn),
        "headers" => headers(conn),
        "method" => conn.method,
        "gzipped" => true
      })

    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("content-encoding", "gzip")
    |> send_resp(200, :zlib.gzip(body))
  end

  get "/brotli" do
    body =
      JSON.encode!(%{
        "origin" => origin(conn),
        "headers" => headers(conn),
        "method" => conn.method,
        "brotli" => true
      })

    {:ok, encoded} = :brotli.encode(body)

    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("content-encoding", "br")
    |> send_resp(200, encoded)
  end

  match _ do
    send_resp(conn, 404, "")
  end

  ## Helpers

  defp render(conn, keys) do
    conn = fetch_query_params(conn)
    parts = parts(conn)

    full = %{
      "url" => url(conn),
      "args" => conn.query_params,
      "form" => parts.form,
      "data" => parts.data,
      "files" => parts.files,
      "json" => parts.json,
      "headers" => headers(conn),
      "origin" => origin(conn),
      "method" => conn.method
    }

    json(conn, 200, Map.take(full, keys))
  end

  defp parts(conn) do
    case get_req_header(conn, "content-type") |> List.first() do
      "application/x-www-form-urlencoded" <> _ ->
        %{form: conn.body_params, files: %{}, data: "", json: nil}

      "multipart/form-data" <> _ ->
        {form, files} = split_multipart(conn.body_params)
        %{form: form, files: files, data: "", json: nil}

      "application/json" <> _ ->
        %{form: %{}, files: %{}, data: conn.assigns.raw_body, json: conn.body_params}

      _ ->
        raw = conn.assigns.raw_body
        %{form: %{}, files: %{}, data: json_safe(raw), json: try_json(raw)}
    end
  end

  defp split_multipart(params) do
    Enum.reduce(params, {%{}, %{}}, fn
      {key, %Plug.Upload{path: path}}, {form, files} ->
        {form, Map.put(files, key, File.read!(path))}

      {key, value}, {form, files} when is_binary(value) ->
        {Map.put(form, key, value), files}
    end)
  end

  defp json_safe(""), do: ""

  defp json_safe(binary) do
    if String.valid?(binary) do
      binary
    else
      "data:application/octet-stream;base64," <> Base.encode64(binary)
    end
  end

  defp try_json(""), do: nil

  defp try_json(binary) do
    case JSON.decode(binary) do
      {:ok, decoded} -> decoded
      {:error, _} -> nil
    end
  end

  defp range_bytes(first, last) do
    for i <- first..last, into: <<>>, do: <<?a + rem(i, 26)>>
  end

  defp digest_challenge(conn, qop) do
    nonce = md5(:crypto.strong_rand_bytes(10))
    opaque = md5(:crypto.strong_rand_bytes(10))

    header =
      ~s|Digest realm="httpbin", nonce="#{nonce}", qop="#{qop}", | <>
        ~s|opaque="#{opaque}", algorithm=MD5, stale=FALSE|

    conn
    |> put_resp_header("www-authenticate", header)
    |> send_resp(401, "")
  end

  defp digest_response(credentials, method, password) do
    ha1 = md5("#{credentials["username"]}:#{credentials["realm"]}:#{password}")
    ha2 = md5("#{method}:#{credentials["uri"]}")

    case credentials["qop"] do
      nil ->
        md5("#{ha1}:#{credentials["nonce"]}:#{ha2}")

      qop ->
        md5(
          "#{ha1}:#{credentials["nonce"]}:#{credentials["nc"]}:" <>
            "#{credentials["cnonce"]}:#{qop}:#{ha2}"
        )
    end
  end

  defp parse_digest(params) do
    for part <- String.split(params, ","), into: %{} do
      [key, value] = part |> String.trim() |> String.split("=", parts: 2)
      {key, String.trim(value, "\"")}
    end
  end

  defp md5(data), do: :crypto.hash(:md5, data) |> Base.encode16(case: :lower)

  defp json(conn, status, data) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode!(data))
  end

  defp headers(conn) do
    Map.new(conn.req_headers, fn {name, value} ->
      {name |> String.split("-") |> Enum.map_join("-", &String.capitalize/1), value}
    end)
  end

  defp origin(conn) do
    conn.remote_ip |> :inet.ntoa() |> to_string()
  end

  defp url(conn) do
    conn = fetch_query_params(conn)

    port =
      case conn do
        %{scheme: :http, port: 80} -> ""
        %{scheme: :https, port: 443} -> ""
        %{port: p} -> ":#{p}"
      end

    base = "#{conn.scheme}://#{conn.host}#{port}#{conn.request_path}"

    if conn.query_string in [nil, ""] do
      base
    else
      base <> "?" <> conn.query_string
    end
  end
end
