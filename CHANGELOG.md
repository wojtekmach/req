# CHANGELOG

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

  * Fix `Req.append_request_steps/2` and `Req.prepend_request_steps/2` (they did the opposite)
  * Add `Req.finch/1`

## v0.1.0 (2021-07-15)

  * Initial release
