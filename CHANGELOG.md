# CHANGELOG

## v0.3.0-dev

Major changes:

  * Add high-level functional API: `Req.new(...) |> Req.request(...)`, `Req.new(...) |>
    Req.get!(...)`, etc.

  * Add `Req.Request.options` field that steps can read from. Also, make
    all steps be arity 1.

    When using "High-level" API, we now run all steps by default. (The
    steps, by looking at request.options, can decide to be no-op.)

  * Add `Req.Request.adapter` field

  * Move low-level API to `Req.Request`

  * Move built-in steps to `Req.Steps`

  * Remove `put_default_steps` step

  * Remove `run_steps` step

  * Remove `Req.Request.unix_socket` field. Add option on `run_finch` step with the same name
    instead.

Step changes:

  * `put_base_url`: Ignore base URL if given URL contains scheme

Deprecations:

  * Deprecate calling `Req.post!(url, body)` in favour of `Req.post(url, body: body)`. Same for `Req.put!`.

  * Deprecate setting `retry: [delay: delay, max_retries: max_retries]`
    in favour of `retry_delay: delay, max_retries: max_retries`.

  * Deprecate setting `follow_redirects: [location_trusted: trusted]`
    in favour of `location_trusted: trusted`.

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
