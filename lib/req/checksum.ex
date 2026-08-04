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

      iex> resp = Req.get!("https://httpbin.org/json", checksum: "sha1:9274ffd9cf273d4a008750f44540c4c5d4c8227c")
      iex> resp.status
      200

      iex> Req.get!("https://httpbin.org/json", checksum: "sha1:bad")
      ** (Req.ChecksumMismatchError) checksum mismatch
      expected: sha1:bad
      actual:   sha1:9274ffd9cf273d4a008750f44540c4c5d4c8227c
  """

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

  def checksum(request) do
    case Req.Request.get_option(request, :checksum) do
      nil ->
        request

      checksum when is_binary(checksum) ->
        type = checksum_type(checksum)

        case request.into do
          nil ->
            Req.Request.put_private(request, :req_checksum, %{
              type: type,
              expected: checksum,
              hash: :body
            })

          fun when is_function(fun, 2) ->
            hash = legacy_hash_init(type)

            into =
              fn {:data, chunk}, {req, resp} ->
                req = update_in(req.private.req_checksum.hash, &:crypto.hash_update(&1, chunk))
                fun.({:data, chunk}, {req, resp})
              end

            request
            |> Req.Request.put_private(:req_checksum, %{
              type: type,
              expected: checksum,
              hash: hash
            })
            |> Map.replace!(:into, into)

          :self ->
            raise ArgumentError, ":checksum cannot be used with `into: :self`"

          collectable ->
            into = Req.Utils.collect_with_hash(collectable, type)

            request
            |> Req.Request.put_private(:req_checksum, %{
              type: type,
              expected: checksum,
              hash: :collectable
            })
            |> Map.replace!(:into, into)
        end
    end
  end

  defp legacy_hash_init(:sha1), do: legacy_hash_init(:sha)
  defp legacy_hash_init(type), do: :crypto.hash_init(type)

  def verify_checksum({request, response}) do
    if config = request.private[:req_checksum] do
      {response, hash} =
        case config.hash do
          # The most efficient way to do this would be to calculate checksum one chunk
          # at a time but it's not easy to implemenet.
          :body ->
            hash = legacy_hash_init(config.type)
            hash = :crypto.hash_update(hash, response.body)
            {response, :crypto.hash_final(hash)}

          :collectable ->
            {body, hash} = response.body
            {put_in(response.body, body), hash}

          hash ->
            {response, :crypto.hash_final(hash)}
        end

      actual = "#{config.type}:" <> Base.encode16(hash, case: :lower, padding: false)

      if config.expected == actual do
        request = Req.Request.delete_option(request, :req_checksum)
        {request, response}
      else
        exception = Req.ChecksumMismatchError.exception(expected: config.expected, actual: actual)
        {request, exception}
      end
    else
      {request, response}
    end
  end
end
