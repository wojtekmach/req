# CHANGELOG

## v0.3.0-dev

Req v0.3.0 brings redesigned API, new steps, and improvements to existing steps.

### New API

The new API allows building a request struct with all the built-in steps. It can be then piped
to functions like `Req.get!/2`:

```elixir
iex> req = Req.new(base_url: "https://api.github.com")

iex> req |> Req.get!(url: "/repos/sneako/finch") |> then(& &1.body["description"])
"Elixir HTTP client, focused on performance"

iex> req |> Req.get(url: "/repos/elixir-mint/mint") |> then(& &1.body["description"])
"Functional HTTP client for Elixir with support for HTTP/1 and HTTP/2."
```

Setting body and encoding it to form/JSON is now done through `:body/:form/:json` options:

```elixir
iex> Req.post!("https://httpbin.org/anything", body: "hello!").body["data"]
"hello!"

iex> req = Req.new(url: "https://httpbin.org/anything")
iex> Req.post!(req, form: [x: 1]).body["form"]
%{"x" => "1"}
iex> Req.post!(req, json: %{x: 2}).body["form"]
%{"x" => 2}
```

### Plug Integration

Req can now be used to easily test plugs using the `:plug` option:

```elixir
defmodule Echo do
  def call(conn, _) do
    "/" <> path = conn.request_path
    Plug.Conn.send_resp(conn, 200, path)
  end
end

test "echo" do
  assert Req.get!("http:///hello", plug: Echo).body == "hello"
end
```

### Request Adapters

While Req always used Finch as the underlying HTTP client, it was designed from the day one to
easily swap it out. This is now even easier with an `:adapter` option.

Here is a mock adapter that always returns a successful response:

```elixir
adapter = fn request ->
  response = %Req.Response{status: 200, body: "it works!"}
  {request, response}
end

Req.request!(url: "http://example").body
#=> "it works!"
```

And here is a naive Hackney-based adapter and how we can use it:

```elixir
hackney = fn request ->
  case :hackney.request(
         request.method,
         URI.to_string(request.url),
         request.headers,
         request.body,
         [:with_body]
       ) do
    {:ok, status, headers, body} ->
      headers = for {name, value} <- headers, do: {String.downcase(name), value}
      response = %Req.Response{status: status, headers: headers, body: body}
      {request, response}

    {:error, reason} ->
      {request, RuntimeError.exception(inspect(reason))}
  end
end

Req.get!("https://api.github.com/repos/elixir-lang/elixir", adapter: hackney).body["description"]
#=> "Elixir is a dynamic, functional language designed for building scalable and maintainable applications"
```

See "Adapter" seciton in `Req.Request` module documentation for more information.

### Major changes

  * Add high-level functional API: `Req.new(...) |> Req.request(...)`, `Req.new(...) |>
    Req.get!(...)`, etc.

  * Add `Req.Request.options` field that steps can read from. Also, make
    all steps be arity 1.

    When using "High-level" API, we now run all steps by default. (The
    steps, by looking at request.options, can decide to be no-op.)

  * Move low-level API to `Req.Request`

  * Move built-in steps to `Req.Steps`

  * Add step names

  * Add `Req.patch!/2`

  * Add `Req.Request.adapter` field

  * Rename `put_if_modified_since` step to `cache`

  * Rename `decompress` step to `decompress_body`

  * Remove `put_default_steps` step

  * Remove `run_steps` step

  * Remove `put_default_headers` step

  * Remove `encode_headers` step. The headers are now encoded in `Req.new/1` and `Req.request/2`

  * Remove `Req.Request.unix_socket` field. Add option on `run_finch` step with the same name
    instead.

### Step changes

  * `put_base_url`: Ignore base URL if given URL contains scheme

  * `run_finch`: Add `:http1` and `:http2` options that pick appropriate default pool started by
    Req

  * `encode_body`: Add `:form` and `:json` options (previously used as `{:form, data}` and
    `{:json, data}`)

  * `cache`: Include request method in cache key

  * `follow_redirects`: Change method to GET on 301..303 redirects

  * `follow_redirects`: Don't send auth headers on redirect to different scheme/host/port
    unless `location_trusted: true` is set

  * `retry`: The `:retry` option can now be set to `:safe` (default) to only retry GET/HEAD
    requests on HTTP 408/5xx responses or exceptions, `:always` to always retry, `:never` to never
    retry, and `fun` - a 1-arity function that accepts either a `Req.Response` or an exception
    struct and returns boolean whether to retry

  * New step: `run_plug`

  * New step: `put_default_user_agent` (replaces part of removed `put_default_headers`)

  * New step: `compressed` (replaces part of removed `put_default_headers`)

  * New step: `compress_body`

  * New step: `output`

  * New step: `handle_http_errors`

### Deprecations

  * Deprecate calling `Req.post!(url, body)` in favour of `Req.post!(url, body: body)`.
    Also, deprecate `Req.post!(url, {:form, data})` in favour of `Req.post!(url, form: data)`.
    and `Req.post!(url, {:json, data})` in favour of `Req.post!(url, json: data)`. Same for
    `Req.put!/2`.

  * Deprecate setting `retry: [delay: delay, max_retries: max_retries]`
    in favour of `retry_delay: delay, max_retries: max_retries`.

  * Deprecate setting `cache: [dir: dir]` in favour of `cache_dir: dir`.

  * `Req.Request`: Deprecate `build/3` in favour of manually building the struct.

## v0.2.1 (2021-11-24)

  * Add `:private` field to Response
  * Update Finch to 0.9.1

## v0.2.0 (2021-11-08)

  * Rename `normalize_headers` to `encode_headers`
  * Rename `prepend_default_steps` to `put_default_steps`
  * Rename `encode` and `decode` to `encode_body` and `decode_body`
  * Rename `netrc` to `load_netrc`
  * Rename `finch` step to `run_finch`
  * Rename `if_modified_since` to `put_if_modified_since`
  * Rename `range` to `put_range`
  * Rename `params` to `put_params`
  * Rename `request.uri` to `request.url`
  * Change response/error step contract from `f(req, resp_err)` to `f({req, resp_err})`
  * Support mime 2.x
  * Add `Req.Response` struct
  * Add `put!/3` and `delete!/2`
  * Add `run_steps/2`
  * Initial support for UNIX domain sockets
  * Accept `{module, args}` and `module` as steps
  * Ensure `get_private` and `put_private` have atom keys
  * `put_default_steps`: Use MFArgs instead of captures for the default steps
  * `put_if_modified_since`: Fix generating internet time
  * `encode_headers`: Encode header values
  * `retry`: Rename `:max_attempts` to `:max_retries`

## v0.1.1 (2021-07-16)

  * Fix `append_request_steps/2` and `prepend_request_steps/2` (they did the opposite)
  * Add `finch/1`

## v0.1.0 (2021-07-15)

  * Initial release
