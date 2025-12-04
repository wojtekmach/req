# Req

[![CI](https://github.com/wojtekmach/req/actions/workflows/ci.yml/badge.svg)](https://github.com/wojtekmach/req/actions/workflows/ci.yml)
[![License](https://img.shields.io/hexpm/l/req.svg)](https://github.com/wojtekmach/req/blob/main/LICENSE.md)
[![Version](https://img.shields.io/hexpm/v/req.svg)](https://hex.pm/packages/req)
[![Hex Docs](https://img.shields.io/badge/documentation-gray.svg)](https://hexdocs.pm/req)

Req is a batteries-included HTTP client for Elixir.

With just a couple lines of code:

```elixir
Mix.install([
  {:req, "~> 0.5.0"}
])

Req.get!("https://api.github.com/repos/wojtekmach/req").body["description"]
#=> "Req is a batteries-included HTTP client for Elixir."
```

we get automatic response body decompression & decoding, following redirects, retrying on errors,
and much more. Virtually all of the features are broken down into individual functions called
_steps_. You can easily re-use and re-arrange built-in steps (see [`Req.Steps`] module) and
write new ones.

## Features

  * An easy to use high-level API: [`Req.request/1`], [`Req.new/1`], [`Req.get!/2`], [`Req.post!/2`], etc.

  * Extensibility via request, response, and error steps.

  * Request body compression (via [`compress_body`] step)

  * Automatic response body decompression (via [`compressed`] and [`decompress_body`] steps). Supports gzip, brotli, and zstd.

  * Request body encoding. Supports urlencoded and multipart forms, and JSON. See [`encode_body`].

  * Automatic response body decoding (via [`decode_body`] step.)

  * Encode params as query string (via [`put_params`] step.)

  * Setting base URL (via [`put_base_url`] step.)

  * Templated request paths (via [`put_path_params`] step.)

  * Basic, Digest, Bearer, and `.netrc`-based authentication (via [`auth`] step.)

  * Range requests (via [`put_range`]) step.)

  * Use AWS V4 Signature (via [`put_aws_sigv4`]) step.)

  * Request body streaming (by setting `body: enumerable`.)

  * Response body streaming (by setting `into: fun | collectable | :self`.)

  * Follows redirects (via [`redirect`] step.)

  * Retries on errors (via [`retry`] step.)

  * Raise on 4xx/5xx errors (via [`handle_http_errors`] step.)

  * Verify response body against a checksum (via [`checksum`] step.)

  * Basic HTTP caching (via [`cache`] step.)

  * Easily create test stubs (see [`Req.Test`].)

  * Running against a plug (via [`run_plug`] step.)

  * Pluggable adapters. By default, Req uses [Finch] (via [`run_finch`] step.)

## Usage

The easiest way to use Req is with [`Mix.install/2`] (requires Elixir v1.12+):

```elixir
Mix.install([
  {:req, "~> 0.5.0"}
])

Req.get!("https://api.github.com/repos/wojtekmach/req").body["description"]
#=> "Req is a batteries-included HTTP client for Elixir."
```

If you want to use Req in a Mix project, you can add the above dependency to your `mix.exs`.

Here's an example POST with JSON data:

```elixir
iex> Req.post!("https://httpbin.org/post", json: %{x: 1, y: 2}).body["json"]
%{"x" => 1, "y" => 2}
```

You can stream request body:

```elixir
iex> stream = Stream.duplicate("foo", 3)
iex> Req.post!("https://httpbin.org/post", body: stream).body["data"]
"foofoofoo"
```

and stream the response body:

```elixir
iex> resp = Req.get!("http://httpbin.org/stream/2", into: IO.stream())
# output: {"url": "http://httpbin.org/stream/2", ...}
# output: {"url": "http://httpbin.org/stream/2", ...}
iex> resp.status
200
iex> resp.body
%IO.Stream{}
```

(See [`Req`] module documentation for more examples of response body streaming.)

If you are planning to make several similar requests, you can build up a request struct with
desired common options and re-use it:

```elixir
req = Req.new(base_url: "https://api.github.com")

Req.get!(req, url: "/repos/sneako/finch").body["description"]
#=> "Elixir HTTP client, focused on performance"

Req.get!(req, url: "/repos/elixir-mint/mint").body["description"]
#=> "Functional HTTP client for Elixir with support for HTTP/1 and HTTP/2."
```

See [`Req.new/1`] for more information on available options.

Virtually all of Req's features are broken down into individual pieces - steps. Req works by running
the request struct through these steps. You can easily reuse or rearrange built-in steps or write new
ones. Importantly, steps are just regular functions. Here is another example where we append a request
step that inspects the URL just before requesting it:

```elixir
req =
  Req.new(base_url: "https://api.github.com")
  |> Req.Request.append_request_steps(
    debug_url: fn request ->
      IO.inspect(URI.to_string(request.url))
      request
    end
  )

Req.get!(req, url: "/repos/wojtekmach/req").body["description"]
# output: "https://api.github.com/repos/wojtekmach/req"
#=> "Req is a batteries-included HTTP client for Elixir."
```

Custom steps can be packaged into plugins so that they are even easier to use by others. See [Related Packages](#related-packages).

Here is how they can be used:

```elixir
Mix.install([
  {:req, "~> 0.5.0"},
  {:req_easyhtml, "~> 0.2.0"},
  {:req_s3, "~> 0.2.3"},
  {:req_hex, "~> 0.2.0"},
  {:req_github_oauth, "~> 0.1.0"}
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

Req.get!(req, url: "s3://ossci-datasets/mnist/t10k-images-idx3-ubyte.gz").body
#=> <<0, 0, 8, 3, ...>>

Req.get!(req, url: "https://repo.hex.pm/tarballs/req-0.1.0.tar").body["metadata.config"]["links"]
#=> %{"GitHub" => "https://github.com/wojtekmach/req"}

Req.get!(req, url: "https://api.github.com/user").body["login"]
# output:
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

See [`Req.Request`] module documentation for more information on low-level API, request struct, and developing plugins.

## Configuration

Req supports many configuration options, see [`Req.new/1`] for a full list and see each step for
more details. In particular, if you are looking for slightly lower level HTTP options such as
timeouts, pool sizes, and certificates, see the [`run_finch`] documentation.

## Related Packages

There are many packages that extend the Req library. To get yours listed here, send a PR.

  * [`req_easyhtml`]
  * [`req_s3`]
  * [`req_hex`]
  * [`req_github_oauth`]
  * [`curl_req`]
  * [`http_cookie`]
  * [`req_embed`]
  * [`req_proxy`]

## Presentations

  * [Req: A batteries-included HTTP client for Elixir - ElixirConf 2023, 2023-09-08](https://www.youtube.com/watch?v=owz2QacFuoQ "ElixirConf 2023 - Wojtek Mach - Req - a batteries-included HTTP client for Elixir")
  * [Req: A batteries included HTTP client for Elixir - Elixir Kenya, 2022-08-26](https://www.youtube.com/watch?v=NxWgvHRN6mI "Req: A batteries included HTTP client for Elixir")

## Development

When developing on macOS, you may need the following linker flags in order to successfully compile [Brotli](https://hexdocs.pm/brotli/readme.html).

```bash
export LDFLAGS="-undefined dynamic_lookup -dynamiclib"
```

## Acknowledgments

Req is built on top of [Finch] and is inspired by [cURL], [Requests], [Tesla], and many other HTTP clients - thank you!

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

[`Req.request/1`]:       https://hexdocs.pm/req/Req.html#request/1
[`Req.new/1`]:           https://hexdocs.pm/req/Req.html#new/1
[`Req.get!/2`]:          https://hexdocs.pm/req/Req.html#get!/2
[`Req.post!/2`]:         https://hexdocs.pm/req/Req.html#post!/2
[`Req`]:                 https://hexdocs.pm/req
[`Req.Request`]:         https://hexdocs.pm/req/Req.Request.html
[`Req.Steps`]:           https://hexdocs.pm/req/Req.Steps.html
[`Req.Test`]:            https://hexdocs.pm/req/Req.Test.html

[`auth`]:               https://hexdocs.pm/req/Req.Steps.html#auth/1
[`cache`]:              https://hexdocs.pm/req/Req.Steps.html#cache/1
[`compress_body`]:      https://hexdocs.pm/req/Req.Steps.html#compress_body/1
[`compressed`]:         https://hexdocs.pm/req/Req.Steps.html#compressed/1
[`decode_body`]:        https://hexdocs.pm/req/Req.Steps.html#decode_body/1
[`decompress_body`]:    https://hexdocs.pm/req/Req.Steps.html#decompress_body/1
[`encode_body`]:        https://hexdocs.pm/req/Req.Steps.html#encode_body/1
[`redirect`]:           https://hexdocs.pm/req/Req.Steps.html#redirect/1
[`handle_http_errors`]: https://hexdocs.pm/req/Req.Steps.html#handle_http_errors/1
[`output`]:             https://hexdocs.pm/req/Req.Steps.html#output/1
[`put_base_url`]:       https://hexdocs.pm/req/Req.Steps.html#put_base_url/1
[`put_params`]:         https://hexdocs.pm/req/Req.Steps.html#put_params/1
[`put_path_params`]:    https://hexdocs.pm/req/Req.Steps.html#put_path_params/1
[`run_plug`]:           https://hexdocs.pm/req/Req.Steps.html#run_plug/1
[`put_range`]:          https://hexdocs.pm/req/Req.Steps.html#put_range/1
[`put_user_agent`]:     https://hexdocs.pm/req/Req.Steps.html#put_user_agent/1
[`retry`]:              https://hexdocs.pm/req/Req.Steps.html#retry/1
[`run_finch`]:          https://hexdocs.pm/req/Req.Steps.html#run_finch/1
[`checksum`]:           https://hexdocs.pm/req/Req.Steps.html#checksum/1
[`put_aws_sigv4`]:       https://hexdocs.pm/req/Req.Steps.html#put_aws_sigv4/1

[Finch]: https://github.com/sneako/finch
[cURL]: https://curl.se
[Requests]: https://docs.python-requests.org/en/master/
[Tesla]: https://github.com/elixir-tesla/tesla
[`req_easyhtml`]: https://github.com/wojtekmach/req_easyhtml
[`req_s3`]: https://github.com/wojtekmach/req_s3
[`req_hex`]: https://github.com/wojtekmach/req_hex
[`req_github_oauth`]: https://github.com/wojtekmach/req_github_oauth
[`Mix.install/2`]: https://hexdocs.pm/mix/Mix.html#install/2
[`curl_req`]: https://github.com/derekkraan/curl_req
[`http_cookie`]: https://github.com/reisub/http_cookie
[`req_embed`]: https://github.com/leandrocp/req_embed
[`req_proxy`]: https://gitlab.com/wmde/technical-wishes/req_proxy
