# CHANGELOG

## v0.3.12 (2023-08-05)

  * `compressed`: Check for optional depenedencies brotli and ezstd only at compile-time.
  * `decode_body`: Check for optional depenedency nimble_csv at compile-time.

## v0.3.11 (2023-07-24)

  * Support `Req.get(options)`, `Req.post(options)`, etc
  * Add [`Req.Request.new/1`]
  * `retry`: Fix returning correct `private.req_retry_count`

## v0.3.10 (2023-06-20)

  * [`decompress_body`]: No-op on non-binary response body
  * [`decompress_body`]: Support multiple `content-encoding` headers
  * [`decode_body`]: Remove `:extract` option
  * Remove deprecated `Req.post!(url, body)` and similar functions

## v0.3.9 (2023-06-08)

  * [`put_path_params`]: URI-encode path params

## v0.3.8 (2023-05-22)

  * Add `:redact_auth` option to redact auth credentials, defaults to `true`.
  * Soft-deprecate `Req.Request.run,run!` in favour of [`Req.Request.run_request/1`].

## v0.3.7 (2023-05-18)

  * Deprecate setting headers to `%NaiveDateTime{}`, always use `%DateTime{}`.
  * [`decode_body`]: Add `:decode_json` option
  * [`follow_redirects`]: Add `:redirect_log_level`
  * [`follow_redirects`]: Preserve HTTP method on 307/308 redirects
  * [`run_finch`]: Allow `:finch_request` to perform the underlying request. This deprecates
    passing 1-arity function `f(finch_request)` in favour of 4-arity
    `f(request, finch_request, finch_name, finch_options)`.

## v0.3.6 (2023-03-06)

  * [`run_finch`]: Fix setting `:hostname` option
  * [`decode_body`]: Add `:extract` option to automatically extract archives (zip, tar, etc)

## v0.3.5 (2023-02-01)

  * New step: [`put_path_params`]
  * [`auth`]: Accept string

## v0.3.4 (2023-01-03)

  * [`retry`]: Add `:retry_log_level` option

## v0.3.3 (2022-12-08)

  * [`follow_redirects`]: Inherit scheme from previous location
  * [`run_finch`]: Fix setting connect timeout
  * [`run_finch`]: Add `:finch_request` option

## v0.3.2 (2022-11-14)

  * [`decode_body`]: Decode JSON when response is json-api mime type
  * [`put_params`]: Fix bug when params have been duplicated when retrying requeset
  * [`retry`]: Remove `retry: :always` option
  * [`retry`]: Soft-deprecate `retry: :never` in favour of `retry: false`
  * [`run_finch`]: Add `:transport_opts`, `:proxy_headers`, `:proxy`, and `:client_settings` options
  * `Req.Response.json/2`: Do not override content-type

## v0.3.1 (2022-09-09)

  * [`encode_body`]: Set Accept header in JSON requests
  * [`put_base_url`]: Fix merging with leading and/or trailing slashes
  * Fix merging :adapter option
  * Add get/2, post/2, put/2, patch/2, delete/2 and head/2

## v0.3.0 (2022-06-21)

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

### Improved Error Handling

Req now validates option names ensuring users didn't accidentally mistyped them.
If they did, it will try to give a helpful error message. Here are some examples:

```elixir
Req.request!(urll: "https://httpbin.org")
** (ArgumentError) unknown option :urll. Did you mean :url?

Req.new(bas_url: "https://httpbin.org")
** (ArgumentError) unknown option :bas_url. Did you mean :base_url?
```

Req also has a new option to handle HTTP errors (4xx/5xx). By default it will continue to
return the error responses:

```elixir
Req.get!("https://httpbin.org/status/404")
#=> %Req.Response{status: 404, ...}
```

but users can now pass `http_errors: :raise` to raise an exception instead:

```elixir
Req.get!("https://httpbin.org/status/404", http_errors: :raise)
** (RuntimeError) The requested URL returned error: 404
Response body: ""
```

This is especially useful in one-off scripts where we only really care about the
"happy path" but would still like to get a good error message when something
unexpected happened.

### Plugins

From the very beginning, Req could be extended with custom steps. To make using such custom steps
by others even easier, they can be packaged up into plugins.

Here are some examples:

  * [`req_easyhtml`](https://github.com/wojtekmach/req_easyhtml)
  * [`req_s3`](https://github.com/wojtekmach/req_s3)
  * [`req_hex`](https://github.com/wojtekmach/req_hex)
  * [`req_github_oauth`](https://github.com/wojtekmach/req_github_oauth)

And here's how they can be used:

```elixir
Mix.install([
  {:req, "~> 0.3.0"},
  {:req_easyhtml, github: "wojtekmach/req_easyhtml"},
  {:req_s3, github: "wojtekmach/req_s3"},
  {:req_hex, github: "wojtekmach/req_hex"},
  {:req_github_oauth, github: "wojtekmach/req_github_oauth"}
])

req =
  (Req.new(http_errors: :raise)
  |> ReqEasyHTML.attach()
  |> ReqS3.attach()
  |> ReqHex.attach()
  |> ReqGitHubOAuth.attach())

Req.get!(req, url: "https://elixir-lang.org").body[".entry-summary h5"]
#=>
# #EasyHTML[<h5>
#    Elixir is a dynamic, functional language for building scalable and maintainable applications.
#  </h5>]

Req.get!(req, url: "s3://ossci-datasets").body
#=>
# [
#   "mnist/",
#   "mnist/t10k-images-idx3-ubyte.gz",
#   "mnist/t10k-labels-idx1-ubyte.gz",
#   "mnist/train-images-idx3-ubyte.gz",
#   "mnist/train-labels-idx1-ubyte.gz"
# ]

Req.get!(req, url: "https://repo.hex.pm/tarballs/req-0.1.0.tar").body["metadata.config"]["links"]
#=> %{"GitHub" => "https://github.com/wojtekmach/req"}

Req.get!(req, url: "https://api.github.com/user").body["login"]
# Outputs:
# paste this user code:
#
#   6C44-30A8
#
# at:
#
#   https://github.com/login/device
#
# open browser window? [Yn]
# 15:22:28.350 [info] response: authorization_pending
# 15:22:33.519 [info] response: authorization_pending
# 15:22:38.678 [info] response: authorization_pending
#=> "wojtekmach"

Req.get!(req, url: "https://api.github.com/user").body["login"]
#=> "wojtekmach"
```

Notice all plugins can be attached to the same request struct which makes it really easy to
explore different endpoints.

See ["Writing Plugins" section in `Req.Request` module documentation](https://hexdocs.pm/req/Req.Request.html#module-writing-plugins)
for more information.

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

you can define plugs as functions too:

```elixir
test "echo" do
  echo = fn conn ->
    "/" <> path = conn.request_path
    Plug.Conn.send_resp(conn, 200, path)
  end

  assert Req.get!("http:///hello", plug: echo).body == "hello"
end
```

which is particularly useful to create HTTP service mocks with tools like
[Bypass](https://github.com/PSPDFKit-labs/bypass).

### Request Adapters

While Req always used Finch as the underlying HTTP client, it was designed from the day one to
easily swap it out. This is now even easier with an `:adapter` option.

Here is a mock adapter that always returns a successful response:

```elixir
adapter = fn request ->
  response = %Req.Response{status: 200, body: "it works!"}
  {request, response}
end

Req.request!(url: "http://example", adapter: adapter).body
#=> "it works!"
```

Here is another one that uses the [`json/2`][resp_json] function to conveniently
return a JSON response:

[resp_json]: https://hexdocs.pm/req/Req.Response.html#json/2

```elixir
adapter = fn request ->
  response = Req.Response.json(%{hello: 42})
  {request, response}
end

resp = Req.request!(url: "http://example", adapter: adapter)
resp.headers
#=> [{"content-type", "application/json"}]
resp.body
#=> %{"hello" => 42}
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

See "Adapter" section in `Req.Request` module documentation for more information.

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

  * Add `Req.head!/2`

  * Add `Req.patch!/2`

  * Add `Req.Request.adapter` field

  * Add `Req.Request.merge_options/2`

  * Add `Req.Request.register_options/2`

  * Add `Req.Request.put_header/3`

  * Add `Req.Request.put_headers/2`

  * Add `Req.Request.put_new_header/3`

  * Add `Req.Request.get_header/2`

  * Add `Req.Request.update_private/4`

  * Add `Req.Response.new/1`

  * Add `Req.Response.json/2`

  * Add `Req.Response.get_header/2`

  * Add `Req.Response.put_header/3`

  * Rename `put_if_modified_since` step to `cache`

  * Rename `decompress` step to `decompress_body`

  * Remove `put_default_steps` step

  * Remove `run_steps` step

  * Remove `put_default_headers` step

  * Remove `encode_headers` step. The headers are now encoded in `Req.new/1` and `Req.request/2`

  * Remove `Req.Request.unix_socket` field. Add option on `run_finch` step with the same name
    instead.

  * Require Elixir 1.12

### Step changes

  * New step: [`put_plug`]

  * New step: [`put_user_agent`] (replaces part of removed `put_default_headers`)

  * New step: [`compressed`] (replaces part of removed `put_default_headers`)

  * New step: [`compress_body`]

  * New step: [`output`]

  * New step: [`handle_http_errors`]

  * [`put_base_url`]: Ignore base URL if given URL contains scheme

  * [`run_finch`]: Add `:connect_options` which dynamically starts (or re-uses already started)
    Finch pool with the given connection options.

  * [`run_finch`]: Replace `:finch_options` with `:receive_timeout` and `:pool_timeout` options

  * [`encode_body`]: Add `:form` and `:json` options (previously used as `{:form, data}` and
    `{:json, data}`)

  * [`cache`]: Include request method in cache key

  * [`decompress_body`], [`compressed`]: Support Brotli

  * [`decompress_body`], [`compressed`]: Support Zstandard

  * [`decode_body`]: Support `decode_body: false` option to disable automatic body decoding

  * [`follow_redirects`]: Change method to GET on 301..303 redirects

  * [`follow_redirects`]: Don't send auth headers on redirect to different scheme/host/port
    unless `location_trusted: true` is set

  * [`retry`]: The `Retry-After` response header on HTTP 429 responses is now respected

  * [`retry`]: The `:retry` option can now be set to `:safe` (default) to only retry GET/HEAD
    requests on HTTP 408/429/5xx responses or exceptions, `:always` to always retry, `:never` to never
    retry, and `fun` - a 1-arity function that accepts either a `Req.Response` or an exception
    struct and returns boolean whether to retry

  * [`retry`]: The `:retry_delay` option now accepts a function that takes a retry count (starting at 0)
    and returns the delay. Defaults to a simple exponential backoff: 1s, 2s, 4s, 8s, ...

### Deprecations

  * Deprecate calling `Req.post!(url, body)` in favour of `Req.post!(url, body: body)`.
    Also, deprecate `Req.post!(url, {:form, data})` in favour of `Req.post!(url, form: data)`.
    and `Req.post!(url, {:json, data})` in favour of `Req.post!(url, json: data)`. Same for
    `Req.put!/2`.

  * Deprecate setting `retry: [delay: delay, max_retries: max_retries]`
    in favour of `retry_delay: delay, max_retries: max_retries`.

  * Deprecate setting `cache: [dir: dir]` in favour of `cache_dir: dir`.

  * Deprecate Req.build/3 in favour of manually building the struct.

## v0.2.2 (2022-04-04)

   * Relax Finch version requirement

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

[`auth`]:                      https://hexdocs.pm/req/Req.Steps.html#auth/1
[`cache`]:                     https://hexdocs.pm/req/Req.Steps.html#cache/1
[`compress_body`]:             https://hexdocs.pm/req/Req.Steps.html#compress_body/1
[`compressed`]:                https://hexdocs.pm/req/Req.Steps.html#compressed/1
[`decode_body`]:               https://hexdocs.pm/req/Req.Steps.html#decode_body/1
[`decompress_body`]:           https://hexdocs.pm/req/Req.Steps.html#decompress_body/1
[`encode_body`]:               https://hexdocs.pm/req/Req.Steps.html#encode_body/1
[`follow_redirects`]:          https://hexdocs.pm/req/Req.Steps.html#follow_redirects/1
[`handle_http_errors`]:        https://hexdocs.pm/req/Req.Steps.html#handle_http_errors/1
[`output`]:                    https://hexdocs.pm/req/Req.Steps.html#output/1
[`put_base_url`]:              https://hexdocs.pm/req/Req.Steps.html#put_base_url/1
[`put_params`]:                https://hexdocs.pm/req/Req.Steps.html#put_params/1
[`put_path_params`]:           https://hexdocs.pm/req/Req.Steps.html#put_path_params/1
[`put_plug`]:                  https://hexdocs.pm/req/Req.Steps.html#put_plug/1
[`put_user_agent`]:            https://hexdocs.pm/req/Req.Steps.html#put_user_agent/1
[`retry`]:                     https://hexdocs.pm/req/Req.Steps.html#retry/1
[`run_finch`]:                 https://hexdocs.pm/req/Req.Steps.html#run_finch/1
[`Req.Request.new/1`]:         https://hexdocs.pm/req/Req.Request.html#new/1
[`Req.Request.run_request/1`]: https://hexdocs.pm/req/Req.Request.html#run_request/1
