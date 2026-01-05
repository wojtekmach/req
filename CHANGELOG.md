# CHANGELOG

## HEAD

  * [`retry`]: Use default delay if `retry-after` is "negative"

    Previously, we were only handling "negative" retry-after in "http date"
    format and slept for zero seconds. We were crashing on retry-after with
    negative seconds.

    Now, we're using the default delay (1s, 2s, 4s, ...) in either format.

## v0.5.16 (2025-11-10)

  * [`Req.Test`]: Fix `verify_on_exit!` accidentally using Mox name
  * [`auth`]: Support MFArgs
  * [`auth`]: Support digest auth
  * [`put_aws_sigv4`]: Support MFArgs
  * [`put_path_params`]: Encode `:path_params` even with reserved characters
  * [`put_path_params`]: Set `:path_params_template` on empty params
  * [`run_plug`]: Handle compressed request body

## v0.5.15 (2025-07-14)

  * [`Req.Response`]: Add [`Req.Response.to_map/1`].

## v0.5.14 (2025-07-02)

  * [`run_plug`]: Remove warning about `into: fun` with `{:halt, acc}` result.

    The warning never been particularly useful because it's not like users
    can do anything about it.

## v0.5.13 (2025-07-02)

  * [`run_plug`]: Ease transition to automatically parsing request body.

    Since v0.5.11, this code:

        plug = fn conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          assert JSON.decode!(body) == %{"x" => 1}
          Plug.Conn.send_resp(conn, 200, "ok")
        end

        Req.put!(plug: plug, json: %{x: 1})

     Needed to be updated to:

        plug = fn conn ->
          assert conn.body_params == %{"x" => 1}
          Plug.Conn.send_resp(conn, 200, "ok")
        end

        Req.put!(plug: plug, json: %{x: 1})

    This change makes it so both work. The latter will be required, however.

## v0.5.12 (2025-06-24)

  * [`run_plug`]: Do not raise on unknown content types.

  * [`Req.Test`]: Improve `Req.Test.transport_error/2` error message.

## v0.5.11 (2025-06-23)

  * [`encode_body`]: Fix leading newline before multipart body.

  * [`run_finch`]: Handle initial transport errors on `into: :self`.

  * [`run_plug`]: Automatically parse request body.

    Prior to this change, users would typically write:

        plug = fn conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          assert JSON.decode!(body) == %{"x" => 1}
          Plug.Conn.send_resp(conn, 200, "ok")
        end

        Req.put!(plug: plug, json: %{x: 1})

    Now, it can be:

        plug = fn conn ->
          assert conn.params == %{"x" => 1}
          Plug.Conn.send_resp(conn, 200, "ok")
        end

        Req.put!(plug: plug, json: %{x: 1})

    This is a **breaking change** as `Plug.Conn.read_body` will now return `""`.

    It can be easily fixed by using [`Req.Test.raw_body/1`] which returns copy of
    the request raw body:

    ```diff
    - {:ok, body, conn} = Plug.Conn.read_body(conn)
    + body = Req.Test.raw_body(conn)
    ```

    Furthermore, prior to this change `conn.body_params` was unfetched:

        plug = fn conn ->
          Plug.Conn.send_resp(conn, 200, inspect(conn.body_params))
        end

        iex> Req.post!(json: %{a: 1}, plug: plug).body
        "%Plug.Conn.Unfetched{aspect: :body_params}"

    Now it is:

        iex> Req.post!(json: %{a: 1}, plug: plug).body
        "%{\"a\": 1}"

    If in your `:plug` usage you look at `conn.params`, it will
    now include `conn.body_params` as Plug always merges them.

  * [`retry`]: Use jitter by default

  * [`Req.Request`]: Add [`Req.Request.put_option/3`].

  * [`Req.Request`]: Add [`Req.Request.put_new_option/3`].

  * [`Req.Request`]: Add [`Req.Request.merge_new_options/2`].

  * [`Req.Test`]: Add [`Req.Test.redirect/2`].

## v0.5.10 (2025-03-21)

  * [`Req`]: Add [`Req.get_headers_list/1`].

## v0.5.9 (2025-03-17)

  * [`encode_body`]: Support any enumerable in `:form_multipart`

  * [`Req.Test.expect/3`]: Fix usage in shared mode

  * [`retry`]: Do not carry halt between retries

  * (Internal) Support custom headers in `Req.Utils.aws_sigv4_url/1`

  * (Internal) Support custom query params in `Req.Utils.aws_sigv4_url/1`

## v0.5.8 (2024-11-29)

  * [`Req`]: Check legacy headers when streaming headers

  * [`Req`]: Ignore :into collectable for non-200 responses

  * [`put_aws_sigv4`]: Fix encoding path

  * [`run_finch`]: Add option to configure Finch `:pool_max_idle_time`

  * [`run_finch`]: Prepare for upcoming Finch v0.20

## v0.5.7 (2024-10-29)

  * [`put_aws_sigv4`]: Fix signature when using custom port

  * [`retry`]: Do not call `retry_delay` fun twice

  * [`auth`]: Support passing a 0-arity function

## v0.5.6 (2024-08-01)

  * Fix compatibility with Elixir v1.13

## v0.5.5 (2024-08-01)

  * [`put_aws_sigv4`]: Fix detecting service

  * [`put_aws_sigv4`]: Raise on no `:access_key_id`/`:secret_access_key`/`:service`

  * [`put_aws_sigv4`]: Fix handling `?name` (no value)

  * [`handle_http_errors`]: should run before `verify_checksum`

  * [`encode_body`]: Support `%File.Stream{}` in `:form_multipart`

  * [`encode_body`]: Support `%File.Stream{}` from other nodes in `:form_multipart`

## v0.5.4 (2024-07-18)

  * [`run_finch`], [`Req.parse_message/2`]: Gracefully handle process messages not meant
    for the asynchronous response. In that case, `Req.parse_message/2` returns `:unknown`.

## v0.5.3 (2024-07-18)

  * [`Req.Test`]: Fix using shared mode

  * [`encode_body`]: Add `:form_multipart` option

  * [`put_aws_sigv4`]: Try detecting the service

  * [`run_finch`]: Fix setting `:finch` option

## v0.5.2 (2024-07-08)

  * [`put_aws_sigv4`]: Fix bug when using custom headers

  * [`put_aws_sigv4`]: Add `:token` option

  * [`redirect`]: Cancel async request before redirecting

  * [`decode_body`]: Support `application/zstd` and `.zst`

## v0.5.1 (2024-06-24)

  * [`retry`]: Default `:retry_log_level` to `:warning`

  * [`put_path_params`]: Add `:path_params_style` option

  * [`put_aws_sigv4`]: Fix path encoding

  * [`decode_body`]: Improve tar detection

  * [`run_finch`]: Fix defaulting to using just HTTP/1

## v0.5.0 (2024-05-28)

Req v0.5.0 brings testing enhancements, errors standardization, `%Req.Response.Async{}`, and more improvements and bug fixes.

### Testing Enhancements

In previous releases, we could only create test _stubs_ (using [`Req.Test.stub/2`]), that is, fake
HTTP servers which had predefined behaviour. Let's say we're integrating with a third-party
weather service and we might create a stub for it like below:

```elixir
Req.Test.stub(MyApp.Weather, fn conn ->
  Req.Test.json(conn, %{"celsius" => 25.0})
end)
```

Anytime we hit this fake we'll get the same result. This works extremely well for simple
integrations however it's not quite enough for more complicated ones. Imagine we're using
something like AWS S3 and we test uploading some data and reading it back again. While we could do
this:

```elixir
Req.Test.stub(MyApp.S3, fn
  conn when conn.method == "PUT" ->
    # ...

  conn when conn.method == "GET" ->
    # ...
end)
```

making the test just a little bit more thorough will make it MUCH more complicated, for example:
the first GET request should return a 404, we then make a PUT, and now GET should return a 200.
We could solve it by adding some state to our test (e.g. an agent) but there is a simpler way and
that is to set request expectations using the new [`Req.Test.expect/3`] function:

```elixir
Req.Test.expect(MyApp.S3, fn conn when conn.method == "GET" ->
  Plug.Conn.send_resp(conn, 404, "not found")
end)

Req.Test.expect(MyApp.S3, fn conn when conn.method == "PUT" ->
  {:ok, body, conn} = Plug.Conn.read_body(conn)
  assert body == "foo"
  Plug.Conn.send_resp(conn, 200, "")
end)

Req.Test.expect(MyApp.S3, fn conn when conn.method == "GET" ->
  Plug.Conn.send_resp(conn, 200, "foo")
end)
```

The important part is the request expectations are meant to run in order (and fail if they don't).

In this release we're also adding [`Req.Test.transport_error/2`], a way to simulate network
errors.

Here is another example using both of the new features, let's simulate a server that is
having issues: on the first request it is not responding and on the following two requests it
returns an HTTP 500. Only on the fourth request it returns an HTTP 200. Req by default
automatically retries transient errors (using [`retry`] step) so it will make multiple
requests exercising all of our request expectations:

```elixir
iex> Req.Test.expect(MyApp.S3, &Req.Test.transport_error(&1, :econnrefused))
iex> Req.Test.expect(MyApp.S3, 2, &Plug.Conn.send_resp(&1, 500, "internal server error"))
iex> Req.Test.expect(MyApp.S3, &Plug.Conn.send_resp(&1, 200, "ok"))
iex> Req.get!(plug: {Req.Test, MyApp.S3}).body
# 15:57:06.309 [error] retry: got exception, will retry in 1000ms, 3 attempts left
# 15:57:06.309 [error] ** (Req.TransportError) connection refused
# 15:57:07.310 [error] retry: got response with status 500, will retry in 2000ms, 2 attempts left
# 15:57:09.311 [error] retry: got response with status 500, will retry in 4000ms, 1 attempt left
"ok"
```

Finally, for parity with [Mox](https://hexdocs.pm/mox), we add functions for setting ownership
mode:

  * [`Req.Test.set_req_test_from_context/1`]
  * [`Req.Test.set_req_test_to_private/1`]
  * [`Req.Test.set_req_test_to_shared/1`]

And for verifying expectations:

  * [`Req.Test.verify!/0`]
  * [`Req.Test.verify!/1`]
  * [`Req.Test.verify_on_exit!/1`]

Thanks to Andrea Leopardi for driving the testing improvements.

### Standardized Errors

In previous releases, when using the default adapter, Finch, Req could return these exceptions on
network/protocol errors: `Mint.TransportError`, `Mint.HTTPError`, and `Finch.Error`. They have
now been standardized into: [`Req.TransportError`] and [`Req.HTTPError`] for more consistent
experience. In fact, this standardization was the pre-requisite of adding
[`Req.Test.transport_error/2`]!

Two additional exception structs have been added: [`Req.ArchiveError`] and [`Req.DecompressError`]
for zip/tar/etc errors in [`decode_body`] and gzip/br/zstd/etc errors in [`decompress_body`]
respectively. Additionally, [`decode_body`] now returns `Jason.DecodeError` instead of raising it.

### `%Req.Response.Async{}`

In previous releases we added ability to stream response body chunks into the current process
mailbox using the `into: :self` option. When such is used, the `response.body` is now set to
[`Req.Response.Async`] struct which implements the [`Enumerable`] protocol.

Here's a quick example:

```elixir
resp = Req.get!("http://httpbin.org/stream/2", into: :self)
resp.body
#=> #Req.Response.Async<...>
Enum.each(resp.body, &IO.puts/1)
# {"url": "http://httpbin.org/stream/2", ..., "id": 0}
# {"url": "http://httpbin.org/stream/2", ..., "id": 1}
```

Here is another example where we use Req to talk to two different servers. The first server
produces some test data, strings `"foo"`, `"bar"` and `"baz"`. The second one is an "echo" server, it simply
responds with the request body it returned. We then stream data from one server, transform it, and
stream it to the other one:

```elixir
Mix.install([
  {:req, "~> 0.5"},
  {:bandit, "~> 1.0"}
])

{:ok, _} =
  Bandit.start_link(
    scheme: :http,
    port: 4000,
    plug: fn conn, _ ->
      conn = Plug.Conn.send_chunked(conn, 200)
      {:ok, conn} = Plug.Conn.chunk(conn, "foo")
      {:ok, conn} = Plug.Conn.chunk(conn, "bar")
      {:ok, conn} = Plug.Conn.chunk(conn, "baz")
      conn
    end
  )

{:ok, _} =
  Bandit.start_link(
    scheme: :http,
    port: 4001,
    plug: fn conn, _ ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      Plug.Conn.send_resp(conn, 200, body)
    end
  )

resp = Req.get!("http://localhost:4000", into: :self)
stream = resp.body |> Stream.with_index() |> Stream.map(fn {data, idx} -> "[#{idx}]#{data}" end)
Req.put!("http://localhost:4001", body: stream).body
#=> "[0]foo[1]bar[2]baz"
```

`Req.Response.Async` is an experimental feature which may change in the future.

The existing caveats to `into: :self` still apply, that is:

  * If the request is sent using HTTP/1, an extra process is spawned to consume messages from the
    underlying socket.

  * On both HTTP/1 and HTTP/2 the messages are sent to the current process as soon as they arrive,
    as a firehose with no back-pressure.

If you wish to maximize request rate or have more control over how messages are streamed, use
`into: fun` or `into: collectable` instead.

### Full v0.5.0 CHANGELOG

  * [`Req`]: Deprecate setting `:headers` to values other than string/integer/`DateTime`.
    This is to potentially allow special handling of atom values in the future.

  * [`Req`]: Add `Req.run/2` and `Req.run!/2`.

  * [`Req`]: `into: :self` now sets `response.body` as `Req.Response.Async` which implements
    enumerable.

  * [`Req.Request`]: Deprecate setting `:redact_auth`. It now has no effect. Instead of allowing
    to opt out of, we give an idea what the secret was without revealing it fully:

    ```elixir
    iex> Req.new(auth: {:basic, "foobar:baz"})
    %Req.Request{
      options: %{auth: {:basic, "foo*******"}},
      ...
    }

    iex> Req.new(headers: [authorization: "bearer foobarbaz"])
    %Req.Request{
      headers: %{"authorization" => ["bearer foo******"]},
      ...
    }
    ```

  * [`Req.Request`]: Deprecate `halt/1` in favour of `Req.Request.halt/2`.

  * [`Req.Test`]: Add [`Req.Test.transport_error/2`] to simulate transport errors.

  * [`Req.Test`]: Add [`Req.Test.expect/3`].

  * [`Req.Test`]: Add functions for setting ownership mode: [`Req.Test.set_req_test_from_context/1`], [`Req.Test.set_req_test_to_private/1`],
    [`Req.Test.set_req_test_to_shared/1`] and for verifying expectations: [`Req.Test.verify!/0`], [`Req.Test.verify!/1`], and [`Req.Test.verify_on_exit!/1`].

  * [`Req.Test`]: Add [`Req.Test.html/2`].

  * [`Req.Test`]: Add [`Req.Test.text/2`].

  * [`Req.Test`]: Drop `:nimble_ownership` dependency.

  * [`Req.Test`]: Deprecate `Req.Test.stub/1`, i.e. the intended use case is to only work
    with _plug_ stubs/mocks.

  * [`decode_body`]: Return `Jason.DecodeError` on JSON errors instead of raising it.

  * [`decode_body`]: Return [`Req.ArchiveError`] on tar/zip errors.

  * [`decompress_body`]: Return [`Req.DecompressError`].

  * [`put_aws_sigv4`]: Drop `:aws_signature` dependency.

  * [`retry`]: **(BREAKING CHANGE)** Consider
    `%Req.TransportError{reason: :closed | :econnrefused | :timeout}` as transient. Previously
    _any_ exceptions with those reason values were consider as such.

  * [`retry`]: **(BREAKING CHANGE)** Consider
    `%Req.HTTPError{protocol: :http2, reason: :unprocessed}` as transient.

  * [`run_finch`]: **(BREAKING CHANGE)** Return [`Req.HTTPError`] instead of `Mint.HTTPError`.

  * [`run_finch`]: **(BREAKING CHANGE)** Return [`Req.TransportError`] instead of `Mint.TransportError`.

  * [`run_finch`]: Set `inet6: true` if URL looks like IPv6 address.

  * [`put_plug`]: Move most documentation to [`run_plug`].

  * [`run_plug`]: Make public.

  * [`run_plug`]: Add support for simulating network issues using [`Req.Test.transport_error/2`].

  * [`run_plug`]: Support passing 2-arity functions as plugs.

  * [`run_plug`]: Automatically fetch query params.

  * [`verify_checksum`]: Fix handling compressed responses.

## v0.4.14 (2024-03-15)

  * [`redirect`]: Return [`Req.TooManyRedirectsError`] exception.

    Previously we _always_ raised a `RuntimeError`. Besides changing the exception struct, now
    it is _returned_:

        iex> Req.get("https://httpbin.org/redirect/4", max_redirects: 3)
        # 07:08:06.868 [debug] redirecting to /relative-redirect/3
        # 07:08:06.988 [debug] redirecting to /relative-redirect/2
        # 07:08:07.109 [debug] redirecting to /relative-redirect/1
        {:error, %Req.TooManyRedirectsError{max_redirects: 3}}

    When users where using functions like `Req.get!`, the exception will of course still be
    raised.

  * Relax `nimble_ownership` version requirement

  * [`Req.Test`]: Allow plug stub to be a `module` or `{module, options}`

  * [`Req.Test`]: Document stubbing with Broadway

## v0.4.13 (2024-03-07)

  * [`run_finch`]: Default to `connect_options: [protocols: [:http1]]` due to regression
    with HTTP/2 requests over HTTP/1 connections (`protocols: [:http1, :http2]`) with request body
    size exceeding 64kib.

## v0.4.12 (2024-03-06)

  * [`Req`]: Add response body streaming via `into: :self`, [`Req.parse_message/2`],
    and `Req.cancel_async_response/1`.

  * [`Req`]: Deprecate `Req.update/2` in favour of [`Req.merge/2`]

  * [`Req.Test`]: Add [`Req.Test.allow/3`]

  * [`compressed`]: Default `compressed: false` when streaming response body

  * [`put_base_url`]: Allow `:base_url` to be a 0-arity function or MFArgs

  * [`put_plug`]: Do not leak `Plug.Test` messages

## v0.4.11 (2024-02-19)

  * [`Req.Test.json/2`]: Don't crash compilation when Plug is not available

## v0.4.10 (2024-02-19)

  * [`run_finch`]: Default to `connect_options: [protocols: [:http1, :http2]]`.

  * [`run_finch`]: Change version requirement to `~> 0.17`, that is all versions up to `1.0`.

  * [`put_aws_sigv4`]: Support streaming request body.

  * [`auth`]: Always update `authorization` header.

  * [`decode_body`]: Gracefully handle multiple content-type values.

  * [`Req.Request.new/1`]: Use `URI.parse` for now.

## v0.4.9 (2024-02-14)

 * [`retry`]: Raise on invalid return from `:retry_delay` function

 * [`run_finch`]: Update to Finch 0.17

 * [`run_finch`]: Deprecate `connect_options: [protocol: ...]` in favour of
   `connect_options: [protocols: ...]]` which defaults to `[:http1, :http2]`, that is,
   make request using HTTP/1 but if negotiated switch to HTTP/2 over the HTTP/1 connection.

 * New step: [`put_aws_sigv4`] - signs request with AWS Signature Version 4.

## v0.4.8 (2023-12-11)

  * [`put_plug`]: Fix response streaming. Previously we were relying on unreleased
    Plug features (which may never get released). Now, Plug adapter will emit the
    entire response body as one chunk. Thus,
    `plug: plug, into: fn ... -> {:halt, acc} end` is not yet supported as it
    requires Plug changes that are still being discussed. On the flip side,
    we should have much more stable Plug integration regardless of this small
    limitation.

## v0.4.7 (2023-12-11)

  * [`put_plug`]: Don't crash if plug is not installed and :plug is not used

## v0.4.6 (2023-12-11)

  * New step: [`checksum`]
  * [`put_plug`]: Fix response streaming when plug uses `send_resp` or `send_file`
  * [`retry`]: Retry on `:closed`

## v0.4.5 (2023-10-27)

  * `decompress_body`: Remove `content-length` header

  * `auth`: Deprecate `auth: {user, pass}` in favour of `auth: {:basic, "user:pass"}`

  * `Req.Request`: Allow steps to be `{mod, fun, args}`

## v0.4.4 (2023-10-05)

  * `compressed`: Check for optional depenedencies brotli and ezstd only at compile-time.
    (backported from v0.3.12.)

  * `decode_body`: Check for optional depenedency nimble_csv at compile-time.
    (backported from v0.3.12.)

  * `run_finch`: Add `:finch_private` option

## v0.4.3 (2023-09-13)

  * [`Req.new/1`]: Fix setting `:redact_auth`

  * [`Req.Request`]: Add `Req.Request.get_option_lazy/3`

  * [`Req.Request`]: Add `Req.Request.drop_options/2`

## v0.4.2 (2023-09-04)

  * [`put_plug`]: Handle response streaming on Plug 1.15+.

  * Don't warn on mixed-case header names

## v0.4.1 (2023-09-01)

  * Fix Req.Request Inspect regression

## v0.4.0 (2023-09-01)

Req v0.4.0 changes headers to be maps, adds request & response streaming, and improves steps.

### Change Headers to be Maps

Previously headers were lists of name/value tuples, e.g.:

```elixir
[{"content-type", "text/html"}]
```

This is a standard across the ecosystem (with minor difference that some Erlang libraries use
charlists instead of binaries.)

There are some problems with this particular choice though:

  * We cannot use `headers[name]`
  * We cannot use pattern matching

In short, this representation isn't very ergonomic to use.

Now headers are maps of string names and lists of values, e.g.:

```elixir
%{"content-type" => ["text/html"]}
```

This allows `headers[name]` usage:

```elixir
response.headers["content-type"]
#=> ["text/html"]
```

and pattern matching:

```elixir
case Req.request!(req) do
  %{headers: %{"content-type" => ["application/json" <> _]}} ->
    # handle JSON response
end
```

This is a major breaking change. If you cannot easily update your app
or your dependencies, do:

```elixir
# config/config.exs
config :req, legacy_headers_as_lists: true
```

This legacy fallback will be removed on Req 1.0.

There are two other changes to headers in this release.

Header names are now case-insensitive in functions like
`Req.Response.get_header/2`.

Trailer headers, or more precisely trailer fields or simply trailers, are now stored
in a separate `trailers` field on the `%Req.Response{}` struct as long as you use Finch 0.17+.

### Add Request Body Streaming

Req v0.4 adds official support for request body streaming by setting the request body to an
`enumerable`. Here's an example:

```elixir
iex> stream = Stream.duplicate("foo", 3)
iex> Req.post!("https://httpbin.org/post", body: stream).body["data"]
"foofoofoo"
```

The enumerable is passed through request steps and they may change it. For example,
the [`compress_body`] step gzips the request body on the fly.

### Add Response Body Streaming

Req v0.4 also adds response body streaming, via the `:into` option.

Here's an example where we download the first 20kb (by making a _range_ request, via the
[`put_range`] step) of Elixir release zip. We stream the response body into a function
and can handle each body chunk. The function receives a `{:data, data}, {req, resp}` and returns
a `{:cont | :halt, {req, resp}}` tuple.

```elixir
resp =
  Req.get!(
    url: "https://github.com/elixir-lang/elixir/releases/download/v1.15.4/elixir-otp-26.zip",
    range: 0..20_000,
    into: fn {:data, data}, {req, resp} ->
      IO.inspect(byte_size(data), label: :chunk)
      {:cont, {req, resp}}
    end
  )

# output: 17:07:38.131 [debug] redirecting to https://objects.githubusercontent.com/github-production-release-asset-2e6(...)
# output: chunk: 16384
# output: chunk: 3617

resp.status #=> 206
resp.headers["content-range"] #=> ["bytes 0-20000/6801977"]
resp.body #=> ""
```

Notice we only stream response _body_, that is, Req automatically handles HTTP response status and
headers. Once the stream is done, Req passes the response through response steps which allows
following redirects, retrying on errors, etc. Response `body` is set to empty string `""`
which is then ignored by [`decompress_body`], [`decode_body`], and similar steps. If you need
to decompress or decode incoming chunks, you need to do that in your custom `into: fun` function.

As the name `:into` implies, we can also stream response body into any [`Collectable`].
Here's a similar snippet to above where we stream to a file:

```elixir
resp =
  Req.get!(
    url: "https://github.com/elixir-lang/elixir/releases/download/v1.15.4/elixir-otp-26.zip",
    range: 0..20_000,
    into: File.stream!("elixit-otp-26.zip.1")
  )

# output: 17:07:38.131 [debug] redirecting to (...)
resp.status #=> 206
resp.headers["content-range"] #=> ["bytes 0-20000/6801977"]
resp.body #=> %File.Stream{}
```

### Full CHANGELOG

  * Change `request.headers` and `response.headers` to be maps.

  * Ensure `request.headers` and `response.headers` are downcased.

    Per [RFC 9110: HTTP Semantics](https://www.rfc-editor.org/rfc/rfc9110.html),
    HTTP headers should be case-insensitive. However, per
    [RFC 9113: HTTP/2](https://datatracker.ietf.org/doc/html/rfc9113) headers
    must be sent downcased.

    Req headers are now stored internally downcased and all accessor functions
    like [`Req.Response.get_header/2`] are downcasing the given header name.

  * Add `trailers` field to [`Req.Response`] struct. Trailer field is only filled in on Finch 0.17+.

  * Make `request.registered_options` internal representation private.

  * Make `request.options` internal representation private.

    Currently `request.options` field is a map but it may change in the future.
    One possible future change is using keywords lists internally which would
    allow, for example, `Req.new(params: [a: 1]) |> Req.merge(params: [b: 2])`
    to keep duplicate `:params` in `request.options` which would then allow to
    decide the duplicate key semantics on a per-step basis. And so, for example,
    [`put_params`] would _merge_ params but most steps would simply use the
    first value.

    To have some room for manoeuvre in the future we should stop pattern
    matching on `request.options`. Calling `request.options[key]`,
    `put_in(request.options[key], value)`, and
    `update_in(request.options[key], fun)` _is_ allowed.

  * Fix typespecs for some functions

  * Deprecate `output` step in favour of `into: File.stream!(path)`.

  * Rename `follow_redirects` step to [`redirect`]

  * [`redirect`]: Rename `:follow_redirects` option to `:redirect`.

  * [`redirect`]: Rename `:location_trusted` option to `:redirect_trusted`.

  * [`redirect`]: Change HTTP request method to GET only on POST requests that result in 301..303.

    Previously we were changing the method to GET for all 3xx except 307 and 308.

  * [`decompress_body`]: Remove support for `deflate` compression (which was broken)

  * [`decompress_body`]: Don't crash on unknown codec

  * [`decompress_body`]: Fix handling HEAD requests

  * [`decompress_body`]: Re-calculate `content-length` header after decompresion

  * [`decompress_body`]: Remove `content-encoding` header after decompression

  * [`decode_body`]: Do not decode response with `content-encoding` header

  * [`run_finch`]: Add `:inet6` option

  * [`retry`]: Support `retry: :safe_transient` which retries HTTP 408/429/500/502/503/504
    or exceptions with `reason` field set to `:timeout`/`:econnrefused`.

    `:safe_transient` is the new default retry mode. (Previously we retried on 408/429/5xx and
    _any_ exception.)

  * [`retry`]: Support `retry: :transient` which is the same as `:safe_transient` except
    it retries on all HTTP methods

  * [`retry`]: Use `retry-after` header value on HTTP 503 Service Unavailable. Previously
    only HTTP 429 Too Many Requests was using this header value.

  * [`retry`]: Support `retry: &fun/2`. The function receives `request, response_or_exception`
    and returns either:

      * `true` - retry with the default delay

      * `{:delay, milliseconds}` - retry with the given delay

      * `false/nil` - don't retry

  * [`retry`]: Deprecate `retry: :safe` in favour of `retry: :safe_transient`

  * [`retry`]: Deprecate `retry: :never` in favour of `retry: false`

  * [`Req.request/2`]: Improve error message on invalid arguments

  * [`Req.merge/2`]: Do not duplicate headers

  * [`Req.merge/2`]: Merge `:params`

  * [`Req.Request`]: Fix displaying redacted basic authentication

  * [`Req.Request`]: Add [`Req.Request.get_option/3`]

  * [`Req.Request`]: Add [`Req.Request.fetch_option/2`]

  * [`Req.Request`]: Add [`Req.Request.fetch_option!/2`]

  * [`Req.Request`]: Add [`Req.Request.delete_option/2`]

  * [`Req.Response`]: Add [`Req.Response.delete_header/2`]

  * [`Req.Response`]: Add [`Req.Response.update_private/4`]

## v0.3.12 (2023-08-05)

  * `compressed`: Check for optional depenedencies brotli and ezstd only at compile-time.
  * `decode_body`: Check for optional depenedency nimble_csv at compile-time.

## v0.3.11 (2023-07-24)

  * Support `Req.get(options)`, `Req.post(options)`, etc
  * Add [`Req.Request.new/1`]
  * [`retry`]: Fix returning correct `private.req_retry_count`

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

[`auth`]:                https://hexdocs.pm/req/Req.Steps.html#auth/1
[`cache`]:               https://hexdocs.pm/req/Req.Steps.html#cache/1
[`compress_body`]:       https://hexdocs.pm/req/Req.Steps.html#compress_body/1
[`compressed`]:          https://hexdocs.pm/req/Req.Steps.html#compressed/1
[`decode_body`]:         https://hexdocs.pm/req/Req.Steps.html#decode_body/1
[`decompress_body`]:     https://hexdocs.pm/req/Req.Steps.html#decompress_body/1
[`compress_body`]:       https://hexdocs.pm/req/Req.Steps.html#compress_body/1
[`encode_body`]:         https://hexdocs.pm/req/Req.Steps.html#encode_body/1
[`redirect`]:            https://hexdocs.pm/req/Req.Steps.html#redirect/1
[`handle_http_errors`]:  https://hexdocs.pm/req/Req.Steps.html#handle_http_errors/1
[`put_base_url`]:        https://hexdocs.pm/req/Req.Steps.html#put_base_url/1
[`put_params`]:          https://hexdocs.pm/req/Req.Steps.html#put_params/1
[`put_path_params`]:     https://hexdocs.pm/req/Req.Steps.html#put_path_params/1
[`put_plug`]:            https://hexdocs.pm/req/Req.Steps.html#put_plug/1
[`run_plug`]:            https://hexdocs.pm/req/Req.Steps.html#run_plug/1
[`put_user_agent`]:      https://hexdocs.pm/req/Req.Steps.html#put_user_agent/1
[`put_range`]:           https://hexdocs.pm/req/Req.Steps.html#put_range/1
[`retry`]:               https://hexdocs.pm/req/Req.Steps.html#retry/1
[`run_finch`]:           https://hexdocs.pm/req/Req.Steps.html#run_finch/1
[`checksum`]:            https://hexdocs.pm/req/Req.Steps.html#checksum/1
[`verify_checksum`]:     https://hexdocs.pm/req/Req.Steps.html#verify_checksum/1
[`put_aws_sigv4`]:       https://hexdocs.pm/req/Req.Steps.html#put_aws_sigv4/1

[`Req`]:                        https://hexdocs.pm/req/Req.html
[`Req.new/1`]:                  https://hexdocs.pm/req/Req.html#new/1
[`Req.request/2`]:              https://hexdocs.pm/req/Req.html#request/2
[`Req.run/2`]:                  https://hexdocs.pm/req/Req.html#run/2
[`Req.run!/2`]:                 https://hexdocs.pm/req/Req.html#run!/2
[`Req.merge/2`]:                https://hexdocs.pm/req/Req.html#merge/2
[`Req.parse_message/2`]:        https://hexdocs.pm/req/Req.html#merge/2
[`Req.cancel_async_request/1`]: https://hexdocs.pm/req/Req.html#merge/2
[`Req.get_headers_list/1`]:     https://hexdocs.pm/req/Req.html#get_headers_list/1

[`Req.Request`]:                     https://hexdocs.pm/req/Req.Request.html
[`Req.Request.new/1`]:               https://hexdocs.pm/req/Req.Request.html#new/1
[`Req.Request.run_request/1`]:       https://hexdocs.pm/req/Req.Request.html#run_request/1
[`Req.Request.put_option/3`]:        https://hexdocs.pm/req/Req.Request.html#put_option/3
[`Req.Request.put_new_option/3`]:    https://hexdocs.pm/req/Req.Request.html#put_new_option/3
[`Req.Request.merge_options/2`]:     https://hexdocs.pm/req/Req.Request.html#merge_options/2
[`Req.Request.merge_new_options/2`]: https://hexdocs.pm/req/Req.Request.html#merge_new_options/2
[`Req.Request.get_option/3`]:        https://hexdocs.pm/req/Req.Request.html#get_option/3
[`Req.Request.get_option_lazy/2`]:   https://hexdocs.pm/req/Req.Request.html#get_option_lazy/2
[`Req.Request.fetch_option/2`]:      https://hexdocs.pm/req/Req.Request.html#fetch_option/2
[`Req.Request.fetch_option!/2`]:     https://hexdocs.pm/req/Req.Request.html#fetch_option!/2
[`Req.Request.delete_option/2`]:     https://hexdocs.pm/req/Req.Request.html#delete_option/2
[`Req.Request.drop_options/2`]:      https://hexdocs.pm/req/Req.Request.html#drop_options/2
[`Req.Request.update_private/4`]:    https://hexdocs.pm/req/Req.Request.html#update_private/4

[`Req.Response`]:                  https://hexdocs.pm/req/Req.Response.html
[`Req.Response.get_header/2`]:     https://hexdocs.pm/req/Req.Response.html#get_response/2
[`Req.Response.delete_header/2`]:  https://hexdocs.pm/req/Req.Response.html#delete_header/2
[`Req.Response.update_private/4`]: https://hexdocs.pm/req/Req.Response.html#update_private/4
[`Req.Response.to_map/1`]:         https://hexdocs.pm/req/Req.Response.html#to_map/1
[`Req.Response.Async`]:            https://hexdocs.pm/req/Req.Response.Async.html

[`Req.Test`]: https://hexdocs.pm/req/Req.Test.html
[`Req.Test.stub/2`]: https://hexdocs.pm/req/Req.Test.html#stub/2
[`Req.Test.json/2`]: https://hexdocs.pm/req/Req.Test.html#json/2
[`Req.Test.html/2`]: https://hexdocs.pm/req/Req.Test.html#html/2
[`Req.Test.text/2`]: https://hexdocs.pm/req/Req.Test.html#text/2
[`Req.Test.allow/3`]: https://hexdocs.pm/req/Req.Test.html#allow/3
[`Req.Test.raw_body/1`]: https://hexdocs.pm/req/Req.Test.html#raw_body/1
[`Req.Test.transport_error/2`]: https://hexdocs.pm/req/Req.Test.html#transport_error/2
[`Req.Test.expect/3`]: https://hexdocs.pm/req/Req.Test.html#expect/3
[`Req.Test.verify!/0`]: https://hexdocs.pm/req/Req.Test.html#verify!/0
[`Req.Test.verify!/1`]: https://hexdocs.pm/req/Req.Test.html#verify!/1
[`Req.Test.verify_on_exit!/1`]: https://hexdocs.pm/req/Req.Test.html#verify_on_exit!/1
[`Req.Test.set_req_test_from_context/1`]: https://hexdocs.pm/req/Req.Test.html#set_req_test_from_context/1
[`Req.Test.set_req_test_to_private/1`]: https://hexdocs.pm/req/Req.Test.html#set_req_test_to_private/1
[`Req.Test.set_req_test_to_shared/1`]: https://hexdocs.pm/req/Req.Test.html#set_req_test_to_shared/1


[`Req.Steps`]:   https://hexdocs.pm/req/Req.Steps.html

[`Req.TransportError`]: https://hexdocs.pm/req/Req.TransportError.html
[`Req.HTTPError`]: https://hexdocs.pm/req/Req.HTTPError.html
[`Req.TooManyRedirectsError`]: https://hexdocs.pm/req/Req.TooManyRedirectsError.html
[`Req.DecompressError`]: https://hexdocs.pm/req/Req.DecompressError.html
[`Req.ArchiveError`]: https://hexdocs.pm/req/Req.ArchiveError.html

[`Enumerable`]:  https://hexdocs.pm/elixir/Enumerable.html
[`Collectable`]: https://hexdocs.pm/elixir/Collectable.html
