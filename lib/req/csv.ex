defmodule Req.CSV do
  @moduledoc """
  CSV decoding using [nimble_csv].

  This module is used by `Req.Steps.decode_body/1` on `.csv` and `text/csv`.

  [nimble_csv]: https://hex.pm/packages/nimble_csv

  """

  defstruct [:rows, headers: true]

  @doc false
  def decode(string, options \\ []) do
    options = Keyword.validate!(options, headers: true)

    {:ok,
     %Req.CSV{
       rows: NimbleCSV.RFC4180.parse_string(string, skip_headers: false),
       headers: Keyword.fetch!(options, :headers)
     }}
  end

  @doc false
  def fetch(%Req.CSV{} = csv, index) when is_integer(index) do
    case csv |> data() |> Enum.at(index) do
      nil ->
        :error

      row ->
        {:ok, row}
    end
  end

  def fetch(%Req.CSV{} = csv, %Range{} = range) do
    {:ok, csv |> data() |> Enum.slice(range)}
  end

  def fetch(%Req.CSV{} = csv, header) when is_binary(header) do
    case header_index(csv, header) do
      nil ->
        :error

      index ->
        {:ok, csv |> data() |> Enum.map(&Enum.at(&1, index))}
    end
  end

  def fetch(%Req.CSV{} = csv, {selector, header}) when is_binary(header) do
    case header_index(csv, header) do
      nil ->
        :error

      index ->
        with {:ok, selected} <- fetch(csv, selector) do
          case selector do
            %Range{} ->
              {:ok, Enum.map(selected, &Enum.at(&1, index))}

            _index ->
              {:ok, Enum.at(selected, index)}
          end
        end
    end
  end

  defp data(%Req.CSV{headers: false, rows: rows}), do: rows
  defp data(%Req.CSV{rows: []}), do: []
  defp data(%Req.CSV{rows: [_headers | rows]}), do: rows

  defp header_index(%Req.CSV{headers: false}, _header), do: nil
  defp header_index(%Req.CSV{rows: []}, _header), do: nil

  defp header_index(%Req.CSV{rows: [headers | _]}, header) do
    Enum.find_index(headers, &(&1 == header))
  end

  defimpl Enumerable do
    def count(%{rows: rows}) do
      {:ok, length(rows)}
    end

    def member?(%{rows: rows}, element) do
      {:ok, Enum.member?(rows, element)}
    end

    def reduce(%{rows: rows}, acc, fun) do
      Enumerable.List.reduce(rows, acc, fun)
    end

    def slice(_csv) do
      {:error, __MODULE__}
    end
  end

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(csv, opts) do
      shown =
        case opts.limit do
          :infinity ->
            csv.rows

          limit ->
            Enum.take(csv.rows, limit)
        end

      lines =
        case {csv.headers, shown} do
          {true, [headers | rows]} ->
            [header_doc(headers, opts) | Enum.map(rows, &row_doc(&1, opts))]

          {_headers, rows} ->
            Enum.map(rows, &row_doc(&1, opts))
        end

      lines = if length(shown) < length(csv.rows), do: lines ++ ["..."], else: lines

      concat(["#Req.CSV<", nest(concat(Enum.map(lines, &concat(line(), &1))), 2), line(), ">"])
    end

    defp header_doc(row, opts) do
      doc = row |> Enum.map(&dump_cell/1) |> Enum.intersperse(",") |> concat()

      if opts.syntax_colors == [] do
        doc
      else
        concat([IO.ANSI.bright(), doc, IO.ANSI.reset()])
      end
    end

    defp row_doc(row, opts) do
      row
      |> Enum.map(&color_doc(dump_cell(&1), :string, opts))
      |> Enum.intersperse(color_doc(",", :list, opts))
      |> concat()
    end

    defp dump_cell(cell) do
      [[cell]]
      |> NimbleCSV.RFC4180.dump_to_iodata()
      |> IO.iodata_to_binary()
      |> String.trim_trailing("\r\n")
    end
  end
end
