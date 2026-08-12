defmodule Req.Checksum do
  @moduledoc """
  Verifies the response body against the expected checksum.

  ## Request Options

    * `:checksum` - if set, this is the expected response body checksum.

      Can be one of:

        * `"md5:(...)"`
        * `"sha1:(...)"`
        * `"sha256:(...)"`

  ## Examples

      iex> resp = Req.get!("https://httpbingo.org/json", checksum: "sha1:ae5891fe71e8c6432b552b0c3b4394e43f151493")
      iex> resp.status
      200

      iex> Req.get!("https://httpbingo.org/json", checksum: "sha1:bad")
      ** (Req.ChecksumMismatchError) checksum mismatch
      expected: sha1:bad
      actual:   sha1:ae5891fe71e8c6432b552b0c3b4394e43f151493
  """

  @doc false
  def stream(%Req.Request{} = req, acc, fun, state, next) do
    case req.options[:checksum] do
      nil ->
        next.(req, acc, fun, state)

      checksum when is_binary(checksum) ->
        if req.into == :self do
          raise ArgumentError, ":checksum cannot be used with `into: :self`"
        end

        checksum_stream(req, checksum, acc, fun, state, next)
    end
  end

  defp checksum_stream(req, checksum, acc, fun, state, next) do
    type = checksum_type(checksum)

    wrapped = fn
      {:data, data} = event, resp, acc, [hash | state] ->
        hash = :crypto.hash_update(hash, data)
        {tag, resp, acc, state} = fun.(event, resp, acc, state)
        {tag, resp, acc, [hash | state]}

      event, resp, acc, [hash | state] ->
        {tag, resp, acc, state} = fun.(event, resp, acc, state)
        {tag, resp, acc, [hash | state]}
    end

    case next.(req, acc, wrapped, [hash_init(type) | state]) do
      {:ok, resp, acc, [hash | state]} ->
        actual =
          "#{type}:" <> Base.encode16(:crypto.hash_final(hash), case: :lower, padding: false)

        if actual == checksum do
          {:ok, resp, acc, state}
        else
          exception = Req.ChecksumMismatchError.exception(expected: checksum, actual: actual)
          {{:error, exception}, resp, acc, state}
        end

      {tag, resp, acc, [_hash | state]} ->
        {tag, resp, acc, state}
    end
  end

  defp checksum_type("md5:" <> _), do: :md5
  defp checksum_type("sha1:" <> _), do: :sha1
  defp checksum_type("sha256:" <> _), do: :sha256

  defp hash_init(:sha1), do: hash_init(:sha)
  defp hash_init(type), do: :crypto.hash_init(type)
end
