defmodule Req.ZIP do
  @moduledoc ~S"""
  ZIP archive decoding using [`:zip`].

  This module is used by `Req.Steps.decode_body/1` on `.zip` and `application/zip`.

  `%Req.Zip{}` implements `Access`, `Enumerable`, and `Inspect`.

  [`:zip`]: `:zip`

  ## Examples

      iex> resp = Req.get!("https://hexdocs.pm/req/0.7.2/req.epub", decoders: [epub: :zip])
      iex> resp.body
      #Req.ZIP<[
        {"mimetype", "application/epub+zip"},
        {"OEBPS/title.xhtml", "<!DOCTYPE html>\n<html xmlns=\"h" <> ...},
        ...
      ]>
      iex> resp.body["mimetype"]
      "application/epub+zip"
  """

  defstruct [:files]

  @doc false
  def encode!(files) do
    {:ok, {"archive.zip", binary}} = :zip.create("archive.zip", files, [:memory])
    binary
  end

  @doc false
  def decode(binary) when is_binary(binary) do
    case :zip.extract(binary, [:memory]) do
      {:ok, files} ->
        files = Enum.map(files, fn {name, contents} -> {List.to_string(name), contents} end)
        {:ok, %Req.ZIP{files: files}}

      {:error, _reason} ->
        # :zip surfaces an internal `{:badmatch, _}` term here, which is not useful.
        {:error, %Req.ArchiveError{format: :zip, data: binary}}
    end
  end

  @doc false
  def decode!(binary) when is_binary(binary) do
    case decode(binary) do
      {:ok, decoded} ->
        decoded

      {:error, err} ->
        raise err
    end
  end

  @doc false
  def fetch(%Req.ZIP{files: files}, name) do
    case List.keyfind(files, name, 0) do
      {_name, contents} ->
        {:ok, contents}

      nil ->
        :error
    end
  end

  @doc false
  def get_and_update(%Req.ZIP{files: files} = zip, name, fun) do
    current =
      case List.keyfind(files, name, 0) do
        {_name, contents} ->
          contents

        nil ->
          nil
      end

    case fun.(current) do
      {get, update} ->
        {get, %{zip | files: List.keystore(files, name, 0, {name, update})}}

      :pop ->
        {current, %{zip | files: List.keydelete(files, name, 0)}}
    end
  end

  @doc false
  def pop(%Req.ZIP{files: files} = zip, name) do
    case List.keyfind(files, name, 0) do
      {_name, contents} ->
        {contents, %{zip | files: List.keydelete(files, name, 0)}}

      nil ->
        {nil, zip}
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

    def slice(_zip) do
      {:error, __MODULE__}
    end
  end

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(zip, opts) do
      fun = fn {name, contents}, opts ->
        contents_opts = %{
          opts
          | limit: min(opts.limit, 10),
            printable_limit: min(opts.printable_limit, 30)
        }

        concat(["{", to_doc(name, opts), ", ", to_doc(contents, contents_opts), "}"])
      end

      container_doc(force_unfit("#Req.ZIP<["), zip.files, "]>", opts, fun, break: :strict)
    end
  end
end
