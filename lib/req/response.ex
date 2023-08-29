defmodule Req.Response do
  @moduledoc """
  The response struct.

  Fields:

    * `:status` - the HTTP status code.

    * `:headers` - the HTTP response headers. The header names must be downcased.

    * `:body` - the HTTP response body.

    * `:trailers` - the HTTP response trailers. The trailer names must be downcased.

    * `:private` - a map reserved for libraries and frameworks to use.
      Prefix the keys with the name of your project to avoid any future
      conflicts. Only accepts `t:atom/0` keys.
  """

  @type t() :: %__MODULE__{
          status: non_neg_integer(),
          headers: %{binary() => [binary()]},
          body: binary() | term(),
          trailers: %{binary() => [binary()]},
          private: map()
        }

  defstruct status: 200,
            headers: if(Req.MixProject.legacy_headers_as_lists?(), do: [], else: %{}),
            body: "",
            trailers: %{},
            private: %{}

  @doc """
  Returns a new response.

  Expects a keyword list, map, or struct containing the response keys.

  ## Example

      iex> Req.Response.new(status: 200, body: "body")
      %Req.Response{status: 200, headers: %{}, body: "body"}

      iex> finch_response = %Finch.Response{status: 200, headers: [{"content-type", "text/html"}]}
      iex> Req.Response.new(finch_response)
      %Req.Response{status: 200, headers: %{"content-type" => ["text/html"]}, body: ""}

  """
  @spec new(options :: keyword() | map() | struct()) :: t()
  def new(options \\ [])

  def new(options) when is_list(options), do: new(Map.new(options))

  if Req.MixProject.legacy_headers_as_lists?() do
    def new(options) do
      options = Map.take(options, [:status, :headers, :body])
      struct!(__MODULE__, options)
    end
  else
    def new(options) do
      options =
        Map.take(options, [:status, :headers, :body, :trailers])
        |> Map.update(:headers, %{}, fn headers ->
          Enum.reduce(headers, %{}, fn {name, value}, acc ->
            Map.update(acc, name, List.wrap(value), &(&1 ++ List.wrap(value)))
          end)
        end)
        |> Map.update(:trailers, %{}, fn trailers ->
          Enum.reduce(trailers, %{}, fn {name, value}, acc ->
            Map.update(acc, name, List.wrap(value), &(&1 ++ List.wrap(value)))
          end)
        end)

      struct!(__MODULE__, options)
    end
  end

  @doc """
  Builds or updates a response with JSON body.

  ## Example

      iex> Req.Response.json(%{hello: 42})
      %Req.Response{
        status: 200,
        headers: %{"content-type" => ["application/json"]},
        body: ~s|{"hello":42}|
      }

      iex> resp = Req.Response.new()
      iex> Req.Response.json(resp, %{hello: 42})
      %Req.Response{
        status: 200,
        headers: %{"content-type" => ["application/json"]},
        body: ~s|{"hello":42}|
      }

  If the request already contains a 'content-type' header, it is kept as is:

      iex> Req.Response.new()
      iex> |> Req.Response.put_header("content-type", "application/vnd.api+json; charset=utf-8")
      iex> |> Req.Response.json(%{hello: 42})
      %Req.Response{
        status: 200,
        headers: %{"content-type" => ["application/vnd.api+json; charset=utf-8"]},
        body: ~s|{"hello":42}|
      }
  """
  @spec json(t(), body :: term()) :: t()
  def json(response \\ new(), body) do
    response =
      case get_header(response, "content-type") do
        [] ->
          put_header(response, "content-type", "application/json")

        _ ->
          response
      end

    Map.replace!(response, :body, Jason.encode!(body))
  end

  @doc """
  Gets the value for a specific private `key`.
  """
  @spec get_private(t(), key :: atom(), default :: term()) :: term()
  def get_private(%Req.Response{} = response, key, default \\ nil) when is_atom(key) do
    Map.get(response.private, key, default)
  end

  @doc """
  Assigns a private `key` to `value`.
  """
  @spec put_private(t(), key :: atom(), value :: term()) :: t()
  def put_private(%Req.Response{} = response, key, value) when is_atom(key) do
    put_in(response.private[key], value)
  end

  @doc """
  Updates private `key` with the given function.

  If `key` is present in request private map then the existing value is passed to `fun` and its
  result is used as the updated value of `key`. If `key` is not present, `default` is inserted
  as the value of `key`. The default value will not be passed through the update function.

  ## Examples

      iex> resp = %Req.Response{private: %{a: 1}}
      iex> Req.Response.update_private(resp, :a, 11, & &1 + 1).private
      %{a: 2}
      iex> Req.Response.update_private(resp, :b, 11, & &1 + 1).private
      %{a: 1, b: 11}
  """
  @spec update_private(t(), key :: atom(), default :: term(), (atom() -> term())) :: t()
  def update_private(%Req.Response{} = response, key, initial, fun)
      when is_atom(key) and is_function(fun, 1) do
    update_in(response.private, &Map.update(&1, key, initial, fun))
  end

  @doc """
  Returns the values of the header specified by `name`.

  ## Examples

      iex> Req.Response.get_header(response, "content-type")
      ["application/json"]
  """
  @spec get_header(t(), binary()) :: [binary()]
  if Req.MixProject.legacy_headers_as_lists?() do
    def get_header(%Req.Response{} = response, name) when is_binary(name) do
      name = Req.__ensure_header_downcase__(name)

      for {^name, value} <- response.headers do
        value
      end
    end
  else
    def get_header(%Req.Response{} = response, name) when is_binary(name) do
      name = Req.__ensure_header_downcase__(name)
      Map.get(response.headers, name, [])
    end
  end

  @doc """
  Adds a new response header `name` if not present, otherwise replaces the
  previous value of that header with `value`.

  ## Examples

      iex> resp = Req.Response.put_header(resp, "content-type", "application/json")
      iex> resp.headers
      [{"content-type", "application/json"}]
  """
  @spec put_header(t(), binary(), binary()) :: t()
  if Req.MixProject.legacy_headers_as_lists?() do
    def put_header(%Req.Response{} = response, name, value)
        when is_binary(name) and is_binary(value) do
      name = Req.__ensure_header_downcase__(name)
      %{response | headers: List.keystore(response.headers, name, 0, {name, value})}
    end
  else
    def put_header(%Req.Response{} = response, name, value)
        when is_binary(name) and is_binary(value) do
      name = Req.__ensure_header_downcase__(name)
      put_in(response.headers[name], List.wrap(value))
    end
  end

  @doc """
  Deletes the header given by `name`.

  All occurences of the header are deleted, in case the header is repeated multiple times.

  ## Examples

      iex> Req.Response.get_header(resp, "cache-control")
      ["max-age=600", "no-transform"]
      iex> resp = Req.Response.delete_header(resp, "cache-control")
      iex> Req.Response.get_header(resp, "cache-control")
      []

  """
  if Req.MixProject.legacy_headers_as_lists?() do
    def delete_header(%Req.Response{} = response, name) when is_binary(name) do
      name_to_delete = Req.__ensure_header_downcase__(name)

      %Req.Response{
        response
        | headers:
            for(
              {name, value} <- response.headers,
              name != name_to_delete,
              do: {name, value}
            )
      }
    end
  else
    def delete_header(%Req.Response{} = response, name) when is_binary(name) do
      name = Req.__ensure_header_downcase__(name)
      update_in(response.headers, &Map.delete(&1, name))
    end
  end

  @doc """
  Returns the `retry-after` header delay value or nil if not found.
  """
  @spec get_retry_after(t()) :: integer() | nil
  def get_retry_after(response) do
    case get_header(response, "retry-after") do
      [delay] ->
        retry_delay_in_ms(delay)

      [] ->
        nil
    end
  end

  defp retry_delay_in_ms(delay_value) do
    case Integer.parse(delay_value) do
      {seconds, ""} ->
        :timer.seconds(seconds)

      :error ->
        delay_value
        |> parse_http_datetime()
        |> DateTime.diff(DateTime.utc_now(), :millisecond)
        |> max(0)
    end
  end

  @month_numbers %{
    "Jan" => "01",
    "Feb" => "02",
    "Mar" => "03",
    "Apr" => "04",
    "May" => "05",
    "Jun" => "06",
    "Jul" => "07",
    "Aug" => "08",
    "Sep" => "09",
    "Oct" => "10",
    "Nov" => "11",
    "Dec" => "12"
  }

  defp parse_http_datetime(datetime) do
    [_day_of_week, day, month, year, time, "GMT"] = String.split(datetime, " ")
    date = year <> "-" <> @month_numbers[month] <> "-" <> day

    case DateTime.from_iso8601(date <> " " <> time <> "Z") do
      {:ok, valid_datetime, 0} ->
        valid_datetime

      {:error, reason} ->
        raise "cannot parse \"retry-after\" header value #{inspect(datetime)} as datetime, reason: #{reason}"
    end
  end
end
