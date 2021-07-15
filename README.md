# Req

[![CI](https://github.com/wojtekmach/req/actions/workflows/ci.yml/badge.svg)](https://github.com/wojtekmach/req/actions/workflows/ci.yml)

[Docs](http://wojtekmach.pl/docs/req/)

<!-- MDOC !-->

An HTTP client with a focus on composability, built on top of [Finch](https://github.com/keathley/finch).

This is a work in progress!

## Features

  * Extensibility via request, response, and error steps

  * Automatic body decompression (via `decompress/2` step)

  * Automatic body encoding and decoding (via `encode/1` and `decode/2` steps)

  * Encode params as query string (via `params/2` step)

  * Basic authentication (via `auth/2` step)

  * `.netrc` file support (via `netrc/2` step)

  * Range requests (via `range/2` step)

  * Follows redirects (via `follow_redirects/2` step)

  * Retries on errors (via `retry/3` step)

  * Basic HTTP caching (via `if_modified_since/2` step)

## Usage

The easiest way to use Req is with `Mix.install/2` (requires Elixir v1.12+):

```elixir
Mix.install([
  {:req, "~> 0.1.0-dev", github: "wojtekmach/req", branch: "main"}
])

Req.get!("https://api.github.com/repos/elixir-lang/elixir").body["description"]
#=> "Elixir is a dynamic, functional language designed for building scalable and maintainable applications"
```

If you want to use Req in a Mix project, you can add the above
dependency to your mix.exs.

## Low-level API

Under the hood, Req works by passing a request through a series of steps.

The request struct, `%Req.Request{}`, initially contains data like HTTP method and
request headers. You can also add request, response, and error steps to it.

Request steps are used to refine the data that will be sent to the server.

After making the actual HTTP request, we'll either get a HTTP response or an error.
The request, along with the response or error, will go through response or
error steps, respectively.

Nothing is actually executed until we run the pipeline with `Req.run/1`.

Example:

```elixir
Req.build(:get, "https://api.github.com/repos/elixir-lang/elixir")
|> Req.prepend_request_steps([
  &Req.default_headers/1
])
|> Req.prepend_response_steps([
  &Req.decode/2
])
|> Req.run()
#=> {:ok, %{body: %{"description" => "Elixir is a dynamic," <> ...}, ...}, ...}
```

The high-level API shown before:

```elixir
Req.get!("https://api.github.com/repos/elixir-lang/elixir")
```

is equivalent to this composition of lower-level API functions:

```elixir
Req.build(:get, "https://api.github.com/repos/elixir-lang/elixir")
|> Req.prepend_default_steps()
|> Req.run!()
```

(See `Req.build/3`, `Req.prepend_default_steps/2`, and `Req.run!/1` for more information.)

We can also build more complex flows like returning a response from a request step
or an error from a response step. We will explore those next.

### Request steps

A request step is a function that accepts a `request` and returns one of the following:

  * A `request`

  * A `{request, response_or_error}` tuple. In that case no further request steps are executed
    and the return value goes through response or error steps

Examples:

```elixir
def default_headers(request) do
  update_in(request.headers, &[{"user-agent", "req/0.1.0-dev"} | &1])
end

def read_from_cache(request) do
  case ResponseCache.fetch(request) do
    {:ok, response} -> {request, response}
    :error -> request
  end
end
```

### Response and error steps

A response step is a function that accepts a `request` and a `response` and returns one of the
following:

  * A `{request, response}` tuple

  * A `{request, exception}` tuple. In that case, no further response steps are executed but the
    exception goes through error steps

Similarly, an error step is a function that accepts a `request` and an `exception` and returns one
of the following:

  * A `{request, exception}` tuple

  * A `{request, response}` tuple. In that case, no further error steps are executed but the
    response goes through response steps

Examples:

```elixir
def decode(request, response) do
  case List.keyfind(response.headers, "content-type", 0) do
    {_, "application/json" <> _} ->
      {request, update_in(response.body, &Jason.decode!/1)}

    _ ->
      {request, response}
  end
end

def log_error(request, exception) do
  Logger.error(["#{request.method} #{request.url}: ", Exception.message(exception)])
  {request, exception}
end
```

### Halting

Any step can call `Req.Request.halt/1` to halt the pipeline. This will prevent any further steps
from being invoked.

Examples:

```elixir
def circuit_breaker(request) do
  if CircuitBreaker.open?() do
    {Req.Request.halt(request), RuntimeError.exception("circuit breaker is open")}
  else
    request
  end
end
```

<!-- MDOC !-->

## Acknowledgments

Req is built on top of [Finch](http://github.com/keathley/finch) and is inspired by and learnt from [Requests](https://docs.python-requests.org/en/master/), [Tesla](https://github.com/teamon/tesla), and many other HTTP clients - Thank you!

## License

Copyright (c) 2021 Wojtek Mach

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at [http://www.apache.org/licenses/LICENSE-2.0](http://www.apache.org/licenses/LICENSE-2.0)

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
