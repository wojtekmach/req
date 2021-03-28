# Req

## High-level API

```elixir
Req.get!("https://api.github.com/repos/elixir-lang/elixir").body["description"]
#=> "Elixir is a dynamic, functional language designed for building scalable and maintainable applications"
```

## Low-level API

```elixir
Req.build(:get, "https://api.github.com/repos/elixir-lang/elixir")
|> Req.add_request_steps([
  &Req.default_headers/1
])
|> Req.add_response_steps([
  &Req.decode/1
])
|> Req.run()
#=> {:ok, %{body: %{"description" => "Elixir is a dynamic," <> ...}, ...}, ...}
```

## Request steps

Request step is a function that accepts a request struct and returns one of the following:

  * A possibly updated request struct

  * A response or an exception. In that case no further request steps are executed
    and the return value goes through response or error steps

  * A `{:halt, response_or_exception}` tuple which stops the pipeline and immediately returns
    with `{:ok, response}` or `{:error, exception}` respectively

### Examples

```elixir
def default_headers(request) do
  put_new_header(request, "user-agent", "req/0.1.0-dev")
end

def read_from_cache(request) do
  case ResponseCache.fetch(request) do
    {:ok, response} -> response
    :error -> request
  end
end

def circuit_breaker(request) do
  if CircuitBreaker.open?() do
    {:halt, RuntimeError.exception("circuit breaker is open")}
  else
    request
  end
end
```

## Response and error steps

A response step is a function that accepts a response struct and returns one of the following:

  * A possibly updated response struct

  * An exception. In that case, no further response steps are executed but the exception goes
    through error steps

  * A `{:halt, response_or_exception}` tuple which stops the pipeline and immediately returns
    with `{:ok, response}` or `{:error, exception}` respectively

Similarly, an error step is a function that accepts an exception and returns one of the following:

  * A possibly updated exception struct

  * A response. In that case, no further error steps are executed but the response goes
    through response steps

  * A `{:halt, response_or_exception}` tuple which stops the pipeline and immediately returns
    with `{:ok, response}` or `{:error, exception}` respectively

Response and error steps can also be 2-arity functions where the second argument is pipeline
state. The state gives access to the request as well as pipeline transient data. Such steps must
return one of the following:

  * For response step, returning a response continues the pipeline

  * For response step, returning an exception makes it so that no further response steps are
    executed but the exception will go through error steps

  * For error step, returning an exception continues the pipeline

  * For error step, returning a response makes it so that no further error steps are executed but
    the response will go through response steps

  * A `{:halt, response_or_exception}` tuple which stops the pipeline and immediately returns
    with `{:ok, response}` or `{:error, exception}` respectively

### Examples

```elixir
def decode(response) do
  case List.keyfind(response.headers, "content-type", 0) do
    {_, "application/json"} ->
      update_in(response.body, &Jason.decode!/1)

    _ ->
      response
  end
end

def retry(response, state) do
  if response.status < 500 do
    response
  else
    max_attempts = 2
    attempt = get_private(state, :retry_attempt, 0)

    if attempt < max_attempts do
      state = put_private(state, :retry_attempt, attempt + 1)
      {:halt, state.request |> run_request(state) |> elem(1)}
    else
      response
    end
  end
end

def log_error(exception, state) do
  request = state.request
  Logger.error(["#{request.method} #{request.path}: ", Exception.message(exception)])
  {exception, state}
end
```
