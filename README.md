# Req

[![CI](https://github.com/wojtekmach/req/actions/workflows/ci.yml/badge.svg)](https://github.com/wojtekmach/req/actions/workflows/ci.yml)

[Docs](https://hexdocs.pm/req)

<!-- MDOC !-->

Req is an HTTP client with a focus on ease of use and composability, built on top of [Finch](https://github.com/keathley/finch).

## Features

  * Extensibility via request, response, and error steps

  * Automatic body decompression (via [`decompress`](`Req.Steps.decompress/1`) step)

  * Automatic body encoding and decoding (via [`encode_body`](`Req.Steps.encode_body/1`)
    and [`decode_body`](`Req.Steps.decode_body/1`) steps)

  * Encode params as query string (via [`put_params`](`Req.Steps.put_params/2`) step)

  * Basic authentication (via [`auth`](`Req.Steps.auth/2`) step)

  * `.netrc` file support (via [`load_netrc`](`Req.Steps.load_netrc/2`) step)

  * Range requests (via [`put_range`](`Req.Steps.put_range/2`) step)

  * Follows redirects (via [`follow_redirects`](`Req.Steps.follow_redirects/2`) step)

  * Retries on errors (via [`retry`](`Req.Steps.retry/2`) step)

  * Basic HTTP caching (via [`cache`](`Req.Steps.put_if_modified_since/2`) step)

  * Setting base URL (via [`put_base_url`](`Req.Steps.put_base_url/2`) step)

## Usage

The easiest way to use Req is with [`Mix.install/2`](https://hexdocs.pm/mix/Mix.html#install/2) (requires Elixir v1.12+):

```elixir
Mix.install([
  {:req, "~> 0.2.0"}
])

Req.get!("https://api.github.com/repos/elixir-lang/elixir").body["description"]
#=> "Elixir is a dynamic, functional language designed for building scalable and maintainable applications"
```

If you want to use Req in a Mix project, you can add the above
dependency to your `mix.exs`.

Example POST request:

```elixir
Req.post!("https://httpbin.org/post", {:form, comments: "hello!"}).body["form"]
#=> %{"comments" => "hello!"}
```

## Low-level API

Under the hood, Req works by passing a [`%Req.Request{}`](`Req.Request`) struct through a series of steps.

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
Req.Request.build(:get, "https://api.github.com/repos/elixir-lang/elixir")
|> Req.Steps.put_default_steps()
|> Req.Request.run!()
```

(See `Req.Request.build/3`, `Req.Steps.put_default_steps/2`, and `Req.Request.run!/1` for more information.)

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
