defmodule Req.Tar do
  @moduledoc ~S"""
  Tar archive decoding using [`:erl_tar`].

  This module is used by `Req.Steps.decode_body/1` on `.tar`, `.tgz`, `.tar.gz`, and `application/x-tar`.

  [`:erl_tar`]: `:erl_tar`

  ## Examples

      iex> resp = Req.get!("https://repo.hex.pm/docs/req-0.7.2.tar.gz", decoders: [:tgz])
      iex> resp.body
      #Req.Tar<[
        {"404.html", "<!DOCTYPE html>\n<html lang=\"en" <> ...},
        {"Req.ArchiveError.html", "<!DOCTYPE html>\n<html lang=\"en" <> ...},
        ...
      ]>
      iex> binary_part(resp.body["Req.md"], 0, 96)
      "# `Req`\n[🔗](https://github.com/wojtekmach/req/blob/v0.7.2/lib/req.ex#L1)\n\nThe high-level API."
  """

  defstruct [:files]

  @doc false
  def decode(binary) when is_binary(binary) do
    case :erl_tar.extract({:binary, binary}, [:memory | modes(binary)]) do
      {:ok, files} ->
        files = Enum.map(files, fn {name, contents} -> {List.to_string(name), contents} end)
        {:ok, %Req.Tar{files: files}}

      {:error, reason} ->
        {:error, %Req.ArchiveError{format: :tar, data: binary, reason: reason}}
    end
  end

  # gzip magic bytes
  defp modes(<<0x1F, 0x8B, _::binary>>), do: [:compressed]
  defp modes(_binary), do: []

  @doc false
  def fetch(%Req.Tar{files: files}, name) do
    case List.keyfind(files, name, 0) do
      {_name, contents} ->
        {:ok, contents}

      nil ->
        :error
    end
  end

  @doc false
  def get_and_update(%Req.Tar{files: files} = tar, name, fun) do
    current =
      case List.keyfind(files, name, 0) do
        {_name, contents} ->
          contents

        nil ->
          nil
      end

    case fun.(current) do
      {get, update} ->
        {get, %{tar | files: List.keystore(files, name, 0, {name, update})}}

      :pop ->
        {current, %{tar | files: List.keydelete(files, name, 0)}}
    end
  end

  @doc false
  def pop(%Req.Tar{files: files} = tar, name) do
    case List.keyfind(files, name, 0) do
      {_name, contents} ->
        {contents, %{tar | files: List.keydelete(files, name, 0)}}

      nil ->
        {nil, tar}
    end
  end

  defimpl Enumerable do
    def count(%{files: files}) do
      {:ok, length(files)}
    end

    def member?(%{files: files}, element) do
      {:ok, Enum.member?(files, element)}
    end

    def reduce(%{files: files}, acc, fun) do
      Enumerable.List.reduce(files, acc, fun)
    end

    def slice(_tar) do
      {:error, __MODULE__}
    end
  end

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(tar, opts) do
      fun = fn {name, contents}, opts ->
        contents_opts = %{
          opts
          | limit: min(opts.limit, 10),
            printable_limit: min(opts.printable_limit, 30)
        }

        concat(["{", to_doc(name, opts), ", ", to_doc(contents, contents_opts), "}"])
      end

      container_doc(force_unfit("#Req.Tar<["), tar.files, "]>", opts, fun, break: :strict)
    end
  end
end
