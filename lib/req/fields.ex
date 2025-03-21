defmodule Req.Fields do
  @moduledoc false
  # Conveniences for working with HTTP Fields, i.e. HTTP Headers and HTTP Trailers.

  @legacy? Req.MixProject.legacy_headers_as_lists?()

  # Legacy behaviour previously used in Req.Request.new.
  # I plan to use Req.Fields.new, i.e. normalize.
  def new_without_normalize(enumerable)

  if @legacy? do
    def new_without_normalize(enumerable) do
      Enum.to_list(enumerable)
    end
  else
    def new_without_normalize(enumerable) do
      Map.new(enumerable, fn {key, value} ->
        {key, List.wrap(value)}
      end)
    end
  end

  # Legacy behaviour previously used in Req.Response.new.
  # I plan to use Req.Fields.new, i.e. normalize.
  def new_without_normalize_with_duplicates(enumerable)

  if @legacy? do
    def new_without_normalize_with_duplicates(enumerable) do
      Enum.to_list(enumerable)
    end
  else
    def new_without_normalize_with_duplicates(enumerable) do
      Enum.reduce(enumerable, %{}, fn {name, value}, acc ->
        Map.update(acc, name, List.wrap(value), &(&1 ++ List.wrap(value)))
      end)
    end
  end

  @doc """
  Returns fields from a given enumerable.

  ## Examples

      iex> Req.Fields.new(a: 1, b: [1, 2])
      %{"a" => ["1"], "b" => ["1", "2"]}

      iex> Req.Fields.new(%{"a" => ["1"], "b" => ["1", "2"]})
      %{"a" => ["1"], "b" => ["1", "2"]}
  """
  if @legacy? do
    def new(enumerable) do
      for {name, value} <- enumerable do
        {normalize_name(name), normalize_value(value)}
      end
    end
  else
    def new(enumerable) do
      Enum.reduce(enumerable, %{}, fn {name, value}, acc ->
        Map.update(
          acc,
          normalize_name(name),
          normalize_values(List.wrap(value)),
          &(&1 ++ normalize_values(List.wrap(value)))
        )
      end)
    end

    defp normalize_values([value | rest]) do
      [normalize_value(value) | normalize_values(rest)]
    end

    defp normalize_values([]) do
      []
    end
  end

  defp normalize_name(name) when is_atom(name) do
    name |> Atom.to_string() |> String.replace("_", "-") |> ensure_name_downcase()
  end

  defp normalize_name(name) when is_binary(name) do
    ensure_name_downcase(name)
  end

  defp normalize_value(%DateTime{} = datetime) do
    datetime |> DateTime.shift_zone!("Etc/UTC") |> Req.Utils.format_http_date()
  end

  defp normalize_value(%NaiveDateTime{} = datetime) do
    IO.warn("setting field to %NaiveDateTime{} is deprecated, use %DateTime{} instead")
    Req.Utils.format_http_date(datetime)
  end

  defp normalize_value(value) when is_binary(value) do
    value
  end

  defp normalize_value(value) when is_integer(value) do
    Integer.to_string(value)
  end

  defp normalize_value(value) do
    IO.warn(
      "setting field to value other than string, integer, or %DateTime{} is deprecated," <>
        " got: #{inspect(value)}"
    )

    String.Chars.to_string(value)
  end

  @doc """
  Merges `fields1` and `fields2`.

  ## Examples

      iex> Req.Fields.merge(%{"a" => ["1"]}, %{"a" => ["2"], "b" => ["2"]})
      %{"a" => ["2"], "b" => ["2"]}
  """
  def merge(fields1, fields2)

  def merge(old_fields, new_fields) do
    if unquote(@legacy?) do
      new_fields = new(new_fields)
      new_field_names = Enum.map(new_fields, &elem(&1, 0))
      Enum.reject(old_fields, &(elem(&1, 0) in new_field_names)) ++ new_fields
    else
      Map.merge(old_fields, new(new_fields))
    end
  end

  def ensure_name_downcase(name) do
    String.downcase(name, :ascii)
  end

  @doc """
  Returns field values.
  """
  def get_values(fields, name)

  if @legacy? do
    def get_values(fields, name) when is_binary(name) do
      name = ensure_name_downcase(name)

      for {^name, value} <- fields do
        value
      end
    end
  else
    def get_values(fields, name) when is_binary(name) do
      name = ensure_name_downcase(name)
      Map.get(fields, name, [])
    end
  end

  @doc """
  Adds a new field `name` with the given `value` if not present,
  otherwise replaces previous value with `value`.
  """
  def put(fields, name, value)

  if @legacy? do
    def put(fields, name, value) when is_binary(name) and is_binary(value) do
      name = ensure_name_downcase(name)
      List.keystore(fields, name, 0, {name, value})
    end
  else
    def put(fields, name, value) when is_binary(name) and is_binary(value) do
      name = ensure_name_downcase(name)
      put_in(fields[name], List.wrap(value))
    end
  end

  @doc """
  Adds a field `name` unless already present.
  """
  def put_new(fields, name, value)

  if @legacy? do
    def put_new(fields, name, value) when is_binary(name) and is_binary(value) do
      case get_values(fields, name) do
        [] ->
          put(fields, name, value)

        _ ->
          fields
      end
    end
  else
    def put_new(fields, name, value) when is_binary(name) and is_binary(value) do
      name = ensure_name_downcase(name)
      Map.put_new(fields, name, List.wrap(value))
    end
  end

  @doc """
  Deletes the field given by `name`.
  """
  def delete(fields, name)

  if @legacy? do
    def delete(fields, name) when is_binary(name) do
      name_to_delete = ensure_name_downcase(name)

      for {name, value} <- fields,
          name != name_to_delete do
        {name, value}
      end
    end
  else
    def delete(fields, name) when is_binary(name) do
      name = ensure_name_downcase(name)
      Map.delete(fields, name)
    end
  end

  @doc """
  Returns fields as list.
  """
  def get_list(fields)

  if @legacy? do
    def get_list(fields) do
      fields
    end
  else
    def get_list(fields) do
      for {name, values} <- fields,
          value <- values do
        {name, value}
      end
    end
  end
end
