defmodule Req.Checksum do
  @moduledoc false

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
            hash = hash_init(type)

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

  defp checksum_type("md5:" <> _), do: :md5
  defp checksum_type("sha1:" <> _), do: :sha1
  defp checksum_type("sha256:" <> _), do: :sha256

  defp hash_init(:sha1), do: hash_init(:sha)
  defp hash_init(type), do: :crypto.hash_init(type)

  def verify_checksum({request, response}) do
    if config = request.private[:req_checksum] do
      {response, hash} =
        case config.hash do
          # The most efficient way to do this would be to calculate checksum one chunk
          # at a time but it's not easy to implemenet.
          :body ->
            hash = hash_init(config.type)
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
