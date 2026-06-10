# Req HTTP Client Usage Rules

This document outlines the prescribed usage patterns and best practices for the Req HTTP client library when working with coding agents.

## Critical Usage Patterns (IMPORTANT)

### 1. Request Creation and Configuration
**IMPORTANT**: Always use `Req.new/1` to create reusable request structs instead of passing options directly to every request.

```elixir
# ✅ DO: Create reusable request struct
req = Req.new(base_url: "https://api.example.com", headers: [authorization: "Bearer token"])
Req.get!(req, url: "/users")
Req.post!(req, url: "/users", json: %{name: "Alice"})

# ❌ DON'T: Repeat options in every request
Req.get!("https://api.example.com/users", headers: [authorization: "Bearer token"])
Req.post!("https://api.example.com/users", headers: [authorization: "Bearer token"], json: %{name: "Alice"})
```

### 2. Error Handling Strategy
**IMPORTANT**: Use the non-bang versions (`Req.get/2`, `Req.post/2`) for production code where you need to handle errors gracefully. Use bang versions (`Req.get!/2`, `Req.post!/2`) only for quick scripts or when errors should crash the process.

```elixir
# ✅ DO: Handle errors in production code
case Req.get(url) do
  {:ok, response} -> process_response(response)
  {:error, exception} -> handle_error(exception)
end

# ✅ DO: Use bang versions for scripts or when crashes are acceptable
response = Req.get!(url)  # Will raise on error
```

## Essential Request Patterns

### Authentication
**IMPORTANT**: Use the `:auth` option for standard authentication methods instead of manually setting headers.

```elixir
# ✅ DO: Use built-in auth options
req = Req.new(auth: {:bearer, token})
req = Req.new(auth: {:basic, "username:password"})
req = Req.new(auth: :netrc)

# ❌ DON'T: Manually set authorization headers
req = Req.new(headers: [authorization: "Bearer #{token}"])
```

### Request Body Encoding
**IMPORTANT**: Use semantic options for request body encoding instead of manual encoding.

```elixir
# ✅ DO: Use semantic encoding options
Req.post!(url, json: %{key: "value"})           # JSON encoding
Req.post!(url, form: [key: "value"])            # URL-encoded form
Req.post!(url, form_multipart: [file: file])    # Multipart form

# ❌ DON'T: Manual encoding and header setting
body = Jason.encode!(%{key: "value"})
Req.post!(url, body: body, headers: ["content-type": "application/json"])
```

### Path Parameters and Query Parameters
**IMPORTANT**: Use `:path_params` for URL path templating and `:params` for query string parameters.

```elixir
# ✅ DO: Use path and query parameter options
req = Req.new(base_url: "https://api.example.com")
Req.get!(req, url: "/users/:id", path_params: [id: 123], params: [include: "profile"])

# ❌ DON'T: Manual URL construction
Req.get!("https://api.example.com/users/#{id}?include=profile")
```

## Response Handling Best Practices

### Response Body Processing
**IMPORTANT**: Req automatically decodes common formats (JSON, gzip, etc.). Don't manually decode unless using `:raw` option.

```elixir
# ✅ DO: Let Req handle decoding automatically
response = Req.get!(json_api_url)
data = response.body  # Already decoded from JSON

# ❌ DON'T: Manual JSON decoding (unless using raw: true)
response = Req.get!(json_api_url)
data = Jason.decode!(response.body)
```

### Response Streaming
**IMPORTANT**: Use `:into` option for streaming large responses or processing data incrementally.

```elixir
# ✅ DO: Stream large responses to file
Req.get!(large_file_url, into: File.stream!("downloaded_file"))

# ✅ DO: Stream and process chunks
Req.get!(stream_url, into: fn {:data, chunk}, {req, resp} ->
  process_chunk(chunk)
  {:cont, {req, resp}}
end)

# ❌ DON'T: Load large responses into memory
response = Req.get!(very_large_file_url)  # May cause memory issues
```

## Configuration and Options

### Retry and Error Handling
**IMPORTANT**: Configure retry behavior explicitly for production systems.

```elixir
# ✅ DO: Configure retry for production
req = Req.new(
  retry: :safe_transient,    # or :transient, or custom function
  max_retries: 3,
  retry_delay: fn n -> n * 1000 end  # Custom backoff
)

# ✅ DO: Disable retry for quick operations
req = Req.new(retry: false)
```

### Timeout Configuration
**IMPORTANT**: Set appropriate timeouts using `:receive_timeout` and `:connect_options`.

```elixir
# ✅ DO: Set reasonable timeouts
req = Req.new(
  receive_timeout: 30_000,  # 30 seconds
  connect_options: [timeout: 5_000]  # 5 seconds to connect
)
```

### HTTP Error Handling
**IMPORTANT**: Configure how 4xx/5xx responses should be handled based on your use case.

```elixir
# ✅ DO: Raise on HTTP errors when appropriate
req = Req.new(http_errors: :raise)

# ✅ DO: Return errors for manual handling (default)
req = Req.new(http_errors: :return)
response = Req.get!(req, url: "/might-be-404")
if response.status == 404, do: handle_not_found()
```

## Advanced Patterns

### Request Steps and Middleware
Use request/response steps for cross-cutting concerns, but prefer built-in options when available.

```elixir
# ✅ DO: Use built-in steps and options first
req = Req.new(compressed: true, decode_body: true)

# ✅ DO: Add custom steps only when necessary
req = Req.new()
|> Req.Request.append_request_steps(
  custom_auth: fn request ->
    # Custom authentication logic
    request
  end
)
```

### Testing with Req
**IMPORTANT**: Use `Req.Test` helpers for creating test stubs instead of external mocking libraries.

```elixir
# ✅ DO: Use Req.Test for HTTP stubs
test "API integration" do
  stub = fn conn ->
    Req.Test.json(conn, %{status: "ok"})
  end
  
  response = Req.get!(plug: stub)
  assert response.body["status"] == "ok"
end
```

## Common Pitfalls to Avoid

### DON'Ts

1. **DON'T** manually encode request bodies when semantic options exist
2. **DON'T** manually set common headers like `content-type`, `authorization`, `user-agent` when options exist  
3. **DON'T** ignore error handling in production code - use non-bang versions
4. **DON'T** hardcode URLs - use `:base_url` and path building
5. **DON'T** load large responses into memory without streaming
6. **DON'T** disable compression unless specifically needed
7. **DON'T** use outdated options (`:follow_redirects` → `:redirect`, `:location_trusted` → `:redirect_trusted`)
8. **DON'T** forget to set timeouts for production systems

### Performance Considerations

- Use connection pooling by reusing the same Finch instance across requests
- Enable compression (default) unless you have specific reasons to disable it
- Stream large request/response bodies using `:body` (enumerable) and `:into` options
- Configure appropriate retry strategies to balance reliability and performance

### Security Considerations

- Use secure authentication methods (`:bearer`, `:basic`) instead of plain header values
- Be cautious with `:redirect_trusted` option - only use when redirects to other hosts are safe
- Validate SSL certificates in production (default behavior)
- Don't log or expose sensitive information in request/response debugging

This usage guide prioritizes the most important patterns first and emphasizes the idiomatic way to use Req's extensive step system and built-in functionality.