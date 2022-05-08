# Req

[![CI](https://github.com/wojtekmach/req/actions/workflows/ci.yml/badge.svg)](https://github.com/wojtekmach/req/actions/workflows/ci.yml)

[Docs](https://hexdocs.pm/req)

Req is an HTTP client with a focus on ease of use and composability, built on top of [Finch](https://github.com/keathley/finch).

(**Note**: This is the README for the current main branch. See [README for Req v0.2.2](https://github.com/wojtekmach/req/tree/v0.2.2#readme))

## Features

  * An easy to use high-level API: [`Req`][req], [`Req.request/1`][req.request], [`Req.get!/2`][req.get!], [`Req.post!/2`][req.post!], etc

  * Extensibility via request, response, and error steps

  * Request body compression and automatic response body decompression (via [`compress_body`][compress_body], [`compressed`][compressed], and [`decompress_body`][decompress_body] steps)

  * Request body encoding and automatic response body decoding (via [`encode_body`][encode_body]
    and [`decode_body`][decode_body] steps)

  * Encode params as query string (via [`put_params`][put_params] step)

  * Basic, bearer, and `.netrc` authentication (via [`auth`][auth] step)

  * Range requests (via [`put_range`][put_range]) step)

  * Follows redirects (via [`follow_redirects`][follow_redirects] step)

  * Retries on errors (via [`retry`][retry] step)

  * Raise on 4xx/5xx errors (via [`handle_http_errors`](handle_http_errors) step)

  * Basic HTTP caching (via [`cache`][cache] step)

  * Setting base URL (via [`put_base_url`][put_base_url] step)

  * Running against a plug (via [`put_plug`][put_plug] step)

  * Pluggable adapters (see ["Adapter" section in `Req.Request` module][adapter] documentation)

[req]: https://hexdocs.pm/req/Req.html
[req.request]: https://hexdocs.pm/req/Req.html#request/1
[req.get!]: https://hexdocs.pm/req/Req.html#get!/2
[req.post!]: https://hexdocs.pm/req/Req.html#post!/2
[compressed]: https://hexdocs.pm/req/Req.Steps.html#compressed/1
[decompress_body]: https://hexdocs.pm/req/Req.Steps.html#decompress_body/1
[encode_body]: https://hexdocs.pm/req/Req.Steps.html#encode_body/1
[decode_body]: https://hexdocs.pm/req/Req.Steps.html#decode_body/1
[put_params]: https://hexdocs.pm/req/Req.Steps.html#put_params/1
[auth]: https://hexdocs.pm/req/Req.Steps.html#auth/1
[put_range]: https://hexdocs.pm/req/Req.Steps.html#put_range/1
[follow_redirects]: https://hexdocs.pm/req/Req.Steps.html#follow_redirects/1
[retry]: https://hexdocs.pm/req/Req.Steps.html#retry/1
[handle_http_errors]: https://hexdocs.pm/req/Req.Steps.html#handle_http_errors/1
[cache]: https://hexdocs.pm/req/Req.Steps.html#cache/1
[put_base_url]: https://hexdocs.pm/req/Req.Steps.html#put_base_url/1
[put_plug]: https://hexdocs.pm/req/Req.Steps.html#put_plug/1
[compress_body]: https://hexdocs.pm/req/Req.Steps.html#compress_body/1
[adapter]: https://hexdocs.pm/req/Req.Request.html#module-adapter

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
%Req.Request{method: :get, url: "https://api.github.com/repos/elixir-lang/elixir"}
|> Req.Request.append_request_steps([
  put_user_agent: &Req.Steps.put_user_agent/1,
  # ...
])
|> Req.Request.append_response_steps([
  retry: &Req.Steps.retry/1,
  follow_redirects: &Req.Steps.follow_redirects/1,
  # ...
|> Req.Request.append_error_steps([
  retry: &Req.Steps.retry/1,
  # ...
])
|> Req.Request.run!()
```

We can also build more complex flows like returning a response from a request step
or an error from a response step. See `Req.Request` documentation for more information.

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
