# Req

[![CI](https://github.com/wojtekmach/req/actions/workflows/ci.yml/badge.svg)](https://github.com/wojtekmach/req/actions/workflows/ci.yml)

[Docs](https://hexdocs.pm/req)

<!-- MDOC !-->

Req is an HTTP client with a focus on ease of use and composability, built on top of [Finch](https://github.com/keathley/finch).

## Features

  * An easy to use high-level API: `Req`, `Req.request/1`, `Req.get!/2`, `Req.post!/2`, etc.

  * Extensibility via request, response, and error steps.

  * Automatic body decompression (via [`decompress`](`Req.Steps.decompress/1`) step)

  * Automatic body encoding and decoding (via [`encode_body`](`Req.Steps.encode_body/1`)
    and [`decode_body`](`Req.Steps.decode_body/1`) steps)

  * Encode params as query string (via [`put_params`](`Req.Steps.put_params/1`) step)

  * Basic, bearer, and `.netrc` authentication (via [`auth`](`Req.Steps.auth/1`) step)

  * Range requests (via [`put_range`](`Req.Steps.put_range/1`) step)

  * Follows redirects (via [`follow_redirects`](`Req.Steps.follow_redirects/1`) step)

  * Retries on errors (via [`retry`](`Req.Steps.retry/1`) step)

  * Basic HTTP caching (via [`cache`](`Req.Steps.put_if_modified_since/1`) step)

  * Setting base URL (via [`put_base_url`](`Req.Steps.put_base_url/1`) step)

## Usage

The easiest way to use Req is with [`Mix.install/2`](https://hexdocs.pm/mix/Mix.html#install/2) (requires Elixir v1.12+):

```elixir
Mix.install([
  {:req, "~> 0.3.0"}
])

Req.get!("https://api.github.com/repos/elixir-lang/elixir").body["description"]
#=> "Elixir is a dynamic, functional language designed for building scalable and maintainable applications"
```

If you want to use Req in a Mix project, you can add the above dependency to your `mix.exs`.

If you are planning to make several similar requests, you can build up a request struct with
desired common options and re-use it:

```elixir
req = Req.new(base_url: "https://api.github.com")

Req.get!(req, url: "/repos/sneako/finch").body["description"]
#=> "Elixir HTTP client, focused on performance"

Req.get!(req, url: "/repos/elixir-mint/mint").body["description"]
#=> "Functional HTTP client for Elixir with support for HTTP/1 and HTTP/2."
```

See [`Req.request/1`](https://hexdocs.pm/req/Req.html#request/1) for more information on available
options.

## How Req Works

Virtually all of Req's functionality is broken down into individual pieces - steps. Req works by
running the request struct through these steps. You can easily reuse or rearrange built-in steps
or write new ones.

There are three types of steps: request, response, and error.

Request steps are used to refine the data that will be sent to the server.

After making the actual HTTP request, we'll either get a HTTP response or an error.
The request, along with the response or error, will go through response or
error steps, respectively.

Nothing is actually executed until we run the pipeline with `Req.Request.run/1`.

The high-level API shown before:

```elixir
Req.get!("https://api.github.com/repos/elixir-lang/elixir")
```

is equivalent to this composition of lower-level API functions and steps:

```elixir
Req.Request.new(method: :get, url: "https://api.github.com/repos/elixir-lang/elixir")
|> Req.Request.append_request_steps([
  &Req.Steps.encode_headers/1,
  &Req.Steps.put_default_headers/1,
  # ...
])
|> Req.Request.append_response_steps([
  &Req.Steps.retry/1,
  &Req.Steps.follow_redirects/1,
  # ...
|> Req.Request.append_error_steps([
  &Req.Steps.retry/1,
  # ...
])
|> Req.Request.run!()
```

We can also build more complex flows like returning a response from a request step
or an error from a response step. See `Req.Request` documentation for more information.

<!-- MDOC !-->

## Acknowledgments

Req is built on top of [Finch](http://github.com/keathley/finch) and is inspired by [cURL](https://curl.se), [Requests](https://docs.python-requests.org/en/master/), [Tesla](https://github.com/teamon/tesla), and many other HTTP clients - thank you!

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
