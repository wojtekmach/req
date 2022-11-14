defmodule Req.Request do
  @moduledoc ~S"""
  The low-level API and the request struct.

  Req is composed of three main pieces:

    * `Req` - the high-level API

    * `Req.Request` - the low-level API and the request struct (you're here!)

    * `Req.Steps` - the collection of built-in steps

  The low-level API and the request struct is the foundation of Req's extensibility. Virtually all
  of the functionality is broken down into individual pieces - steps. Req works by running the
  request struct through these steps. You can easily reuse or rearrange built-in steps or write new
  ones.

  To make using custom steps by others even easier, they can be packaged up into plugins.
  See ["Writing Plugins"](#module-writing-plugins) section for more information.

  ## The Low-level API

  Most Req users would use it like this:

      Req.get!("https://api.github.com/repos/elixir-lang/elixir").body["description"]
      #=> "Elixir is a dynamic, functional language designed for building scalable and maintainable applications"

  Here is the equivalent using the low-level API:

      url = "https://api.github.com/repos/elixir-lang/elixir"

      req =
        %Req.Request{method: :get, url: url}
        |> Req.Request.append_request_steps(
          put_user_agent: &Req.Steps.put_user_agent/1,
          # ...
        )
        |> Req.Request.append_response_steps(
          # ...
          decompress_body: &Req.Steps.decompress_body/1,
          decode_body: &Req.Steps.decode_body/1,
          # ...
        )
        |> Req.Request.append_error_steps(
          retry: &Req.Steps.retry/1,
          # ...
        )

      Req.Request.run!(req).body["description"]
      #=> "Elixir is a dynamic, functional language designed for building scalable and maintainable applications"

  By putting the request pipeline yourself you have precise control of exactly what is running and in what order.

  ## The Request Struct

    * `:method` - the HTTP request method

    * `:url` - the HTTP request URL

    * `:headers` - the HTTP request headers

    * `:body` - the HTTP request body

    * `:options` - the options to be used by steps. See ["Options"](#module-options) section below
      for more information.

    * `:halted` - whether the request pipeline is halted. See `halt/1`

    * `:adapter` - a request step that makes the actual HTTP request. Defaults to
      `Req.Steps.run_finch/1`. See ["Adapter"](#module-adapter) section below for more information.

    * `:request_steps` - the list of request steps

    * `:response_steps` - the list of response steps

    * `:error_steps` - the list of error steps

    * `:private` - a map reserved for libraries and frameworks to use.
      Prefix the keys with the name of your project to avoid any future
      conflicts. Only accepts `t:atom/0` keys.

  ## Steps

  Req has three types of steps: request, response, and error.

  Request steps are used to refine the data that will be sent to the server.

  After making the actual HTTP request, we'll either get a HTTP response or an error.
  The request, along with the response or error, will go through response or
  error steps, respectively.

  Nothing is actually executed until we run the pipeline with `Req.Request.run/1`.

  ### Request steps

  A request step is a function that accepts a `request` and returns one of the following:

    * A `request`

    * A `{request, response_or_error}` tuple. In that case no further request steps are executed
      and the return value goes through response or error steps

  Examples:

      def put_default_headers(request) do
        update_in(request.headers, &[{"user-agent", "req"} | &1])
      end

      def read_from_cache(request) do
        case ResponseCache.fetch(request) do
          {:ok, response} -> {request, response}
          :error -> request
        end
      end

  ### Response and error steps

  A response step is a function that accepts a `{request, response}` tuple and returns one of the
  following:

    * A `{request, response}` tuple

    * A `{request, exception}` tuple. In that case, no further response steps are executed but the
      exception goes through error steps

  Similarly, an error step is a function that accepts a `{request, exception}` tuple and returns one
  of the following:

    * A `{request, exception}` tuple

    * A `{request, response}` tuple. In that case, no further error steps are executed but the
      response goes through response steps

  Examples:

      def decode({request, response}) do
        case List.keyfind(response.headers, "content-type", 0) do
          {_, "application/json" <> _} ->
            {request, update_in(response.body, &Jason.decode!/1)}

          _ ->
            {request, response}
        end
      end

      def log_error({request, exception}) do
        Logger.error(["#{request.method} #{request.uri}: ", Exception.message(exception)])
        {request, exception}
      end

  ### Halting

  Any step can call `halt/1` to halt the pipeline. This will prevent any further steps
  from being invoked.

  Examples:

      def circuit_breaker(request) do
        if CircuitBreaker.open?() do
          {Req.Request.halt(request), RuntimeError.exception("circuit breaker is open")}
        else
          request
        end
      end

  ## Writing Plugins

  Custom steps can be packaged into plugins so that they are even easier to use by others.

  Here's an example plugin:

      defmodule PrintHeaders do
        @doc \"""
        Prints request and response headers.

        ## Request Options

          * `:print_headers` - if `true`, prints the headers. Defaults to `false`.
        \"""
        def attach(%Req.Request{} = request, options \\ []) do
          request
          |> Req.Request.register_options([:print_headers])
          |> Req.Request.merge_options(options)
          |> Req.Request.append_request_steps(print_headers: &print_request_headers/1)
          |> Req.Request.prepend_response_steps(print_headers: &print_response_headers/1)
        end

        defp print_request_headers(request) do
          if request.options[:print_headers] do
            print_headers("> ", request.headers)
          end

          request
        end

        defp print_response_headers({request, response}) do
          if request.options[:print_headers] do
            print_headers("< ", response.headers)
          end

          {request, response}
        end

        defp print_headers(prefix, headers) do
          for {name, value} <- headers do
            IO.puts([prefix, name, ": ", value])
          end
        end
      end

  And here is how we can use it:

      req = Req.new() |> PrintHeaders.attach()

      Req.get!(req, url: "https://httpbin.org/json").status
      200

      Req.get!(req, url: "https://httpbin.org/json", print_headers: true).status
      # Outputs:
      # > accept-encoding: br, gzip, deflate
      # > user-agent: req/0.3.0-dev
      # < date: Wed, 11 May 2022 11:10:47 GMT
      # < content-type: application/json
      # ...
      200

      req = Req.new() |> PrintHeaders.attach(print_headers: true)
      Req.get!(req, url: "https://httpbin.org/json").status
      # Outputs:
      # > accept-encoding: br, gzip, deflate
      # ...
      200

  As you can see a plugin is simply a module. While this is not enforced, the plugin should follow
  these conventions:

    * It should export an `attach/1` function that takes and returns the request struct

    * The attach functions mostly just adds steps and it is the steps that do the actual work

    * A user should be able to attach your plugin alongside other plugins. For this reason,
      plugin functionality should usually only happen on a specific "trigger": on a specific
      option, on a specific URL scheme or host, etc. This is especially important for plugins
      that perform authentication; you don't want to accidentally expose a token from service A
      when a user makes request to service B.

    * If your plugin supports custom options, register them with `register_options/2`

    * Sometimes it is useful to pass options when attaching the plugin. For that, export an
      `attach/2` function and call `merge_options/2`. Remember to first register
      options before merging!

  ## Adapter

  As noted in the ["Request steps"](#module-request-steps) section, a request step besides returning the request,
  might also return `{request, response}` or `{request, exception}`, thus invoking either response or error steps next.
  This is exactly how Req makes the underlying HTTP call, by invoking a request step that follows this contract.

  The default adapter is using Finch via the `Req.Steps.run_finch/1` step.

  Here is a mock adapter that always returns a successful response:

      adapter = fn request ->
        response = %Req.Response{status: 200, body: "it works!"}
        {request, response}
      end

      Req.request!(url: "http://example", adapter: adapter).body
      #=> "it works!"

  Here is another one that uses the `Req.Response.json/2` function to conveniently
  return a JSON response:

      adapter = fn request ->
        response = Req.Response.json(%{hello: 42})
        {request, response}
      end

      resp = Req.request!(url: "http://example", adapter: adapter)
      resp.headers
      #=> [{"content-type", "application/json"}]
      resp.body
      #=> %{"hello" => 42}

  And here is a naive Hackney-based adapter:

      hackney = fn request ->
        case :hackney.request(
               request.method,
               URI.to_string(request.url),
               request.headers,
               request.body,
               [:with_body]
             ) do
          {:ok, status, headers, body} ->
            headers = for {name, value} <- headers, do: {String.downcase(name), value}
            response = %Req.Response{status: status, headers: headers, body: body}
            {request, response}

          {:error, reason} ->
            {request, RuntimeError.exception(inspect(reason))}
        end
      end

      Req.get!("https://api.github.com/repos/elixir-lang/elixir", adapter: hackney).body["description"]
      "Elixir is a dynamic, functional language designed for building scalable and maintainable applications"
  """

  @type t() :: %Req.Request{
          method: atom(),
          url: URI.t(),
          headers: [{binary(), binary()}],
          body: iodata() | nil,
          options: map(),
          registered_options: MapSet.t(),
          halted: boolean(),
          adapter: request_step(),
          request_steps: [{name :: atom(), request_step()}],
          response_steps: [{name :: atom(), response_step()}],
          error_steps: [{name :: atom(), error_step()}],
          private: map()
        }

  @typep request_step() :: fun()
  @typep response_step() :: fun()
  @typep error_step() :: fun()

  defstruct method: :get,
            url: URI.parse(""),
            headers: [],
            body: nil,
            options: %{},
            halted: false,
            adapter: &Req.Steps.run_finch/1,
            request_steps: [],
            response_steps: [],
            error_steps: [],
            private: %{},
            registered_options: MapSet.new(),
            current_request_steps: []

  @doc """
  Gets the value for a specific private `key`.
  """
  def get_private(request, key, default \\ nil) when is_atom(key) do
    Map.get(request.private, key, default)
  end

  @doc """
  Updates private `key` with the given function.

  If `key` is present in request private map then the existing value is passed to `fun` and its
  result is used as the updated value of `key`. If `key` is not present, `default` is inserted
  as the value of `key`. The default value will not be passed through the update function.

  ## Examples

      iex> req = %Req.Request{private: %{a: 1}}
      iex> Req.Request.update_private(req, :a, 11, & &1 + 1).private
      %{a: 2}
      iex> Req.Request.update_private(req, :b, 11, & &1 + 1).private
      %{a: 1, b: 11}
  """
  def update_private(request, key, default, fun) when is_atom(key) and is_function(fun, 1) do
    update_in(request.private, &Map.update(&1, key, default, fun))
  end

  @doc """
  Assigns a private `key` to `value`.
  """
  def put_private(request, key, value) when is_atom(key) do
    put_in(request.private[key], value)
  end

  @doc """
  Halts the request pipeline preventing any further steps from executing.
  """
  def halt(request) do
    %{request | halted: true}
  end

  @doc """
  Appends request steps.

  ## Examples

      Req.Request.append_request_steps(request,
        noop: fn request -> request end,
        inspect: &IO.inspect/1
      )
  """
  def append_request_steps(request, steps) do
    %{
      request
      | request_steps: request.request_steps ++ steps,
        current_request_steps: request.current_request_steps ++ Keyword.keys(steps)
    }
  end

  @doc """
  Prepends request steps.

  ## Examples

      Req.Request.prepend_request_steps(request,
        noop: fn request -> request end,
        inspect: &IO.inspect/1
      )
  """
  def prepend_request_steps(request, steps) do
    %{
      request
      | request_steps: steps ++ request.request_steps,
        current_request_steps: Keyword.keys(steps) ++ request.current_request_steps
    }
  end

  @doc """
  Appends response steps.

  ## Examples

      Req.Request.append_response_steps(request,
        noop: fn {request, response} -> {request, response} end,
        inspect: &IO.inspect/1
      )
  """
  def append_response_steps(request, steps) do
    %{
      request
      | response_steps: request.response_steps ++ steps
    }
  end

  @doc """
  Prepends response steps.

  ## Examples

      Req.Request.prepend_response_steps(request,
        noop: fn {request, response} -> {request, response} end,
        inspect: &IO.inspect/1
      )
  """
  def prepend_response_steps(request, steps) do
    %{
      request
      | response_steps: steps ++ request.response_steps
    }
  end

  @doc """
  Appends error steps.

  ## Examples

      Req.Request.append_error_steps(request,
        noop: fn {request, exception} -> {request, exception} end,
        inspect: &IO.inspect/1
      )
  """
  def append_error_steps(request, steps) do
    %{
      request
      | error_steps: request.error_steps ++ steps
    }
  end

  @doc """
  Prepends error steps.

  ## Examples

      Req.Request.prepend_error_steps(request,
        noop: fn {request, exception} -> {request, exception} end,
        inspect: &IO.inspect/1
      )
  """
  def prepend_error_steps(request, steps) do
    %{
      request
      | error_steps: steps ++ request.error_steps
    }
  end

  @doc false
  def prepare(%{request_steps: [step | steps]} = request) do
    case run_step(step, request) do
      %Req.Request{} = request ->
        request = %{request | request_steps: steps}
        prepare(request)

      {_request, %{__exception__: true} = exception} ->
        raise exception
    end
  end

  def prepare(%Req.Request{request_steps: []} = request) do
    request
  end

  @doc """
  Merges given options into the request.

  ## Examples

      iex> req = Req.new(auth: {"alice", "secret"}, http_errors: :raise)
      iex> req = Req.Request.merge_options(req, auth: {:bearer, "abcd"}, base_url: "https://example.com")
      iex> req.options
      %{auth: {:bearer, "abcd"}, base_url: "https://example.com", http_errors: :raise}
  """
  @spec merge_options(t(), keyword()) :: t()
  def merge_options(%Req.Request{} = request, options) when is_list(options) do
    # TODO: remove on v0.5
    deprecated = [:method, :url, :headers, :body, :adapter]

    options =
      case deprecated -- deprecated -- Keyword.keys(options) do
        [] ->
          options

        deprecated ->
          IO.warn(
            "Passing " <>
              Enum.map_join(deprecated, "/", &inspect/1) <>
              " is deprecated, use Req.update/2 instead."
          )

          Keyword.drop(options, deprecated)
      end

    validate_options(request, options)
    update_in(request.options, &Map.merge(&1, Map.new(options)))
  end

  @doc """
  Returns the values of the header specified by `key`.

  ## Examples

      iex> req = Req.new(headers: [{"accept", "application/json"}])
      iex> Req.Request.get_header(req, "accept")
      ["application/json"]

  """
  @spec get_header(t(), binary()) :: [binary()]
  def get_header(%Req.Request{} = request, key) when is_binary(key) do
    for {^key, value} <- request.headers, do: value
  end

  @doc """
  Adds a new request header (`key`) if not present, otherwise replaces the
  previous value of that header with `value`.

  Because header keys are case-insensitive in both HTTP/1.1 and HTTP/2,
  it is recommended for header keys to be in lowercase, to avoid sending
  duplicate keys in a request.

  Additionally, requests with mixed-case headers served over HTTP/2 are not
  considered valid by common clients, resulting in dropped requests.

  ## Examples

      iex> req = Req.new()
      iex> req = Req.Request.put_header(req, "accept", "application/json")
      iex> req.headers
      [{"accept", "application/json"}]

  """
  @spec put_header(t(), binary(), binary()) :: t()
  def put_header(%Req.Request{} = request, key, value)
      when is_binary(key) and is_binary(value) do
    %{request | headers: List.keystore(request.headers, key, 0, {key, value})}
  end

  @doc """
  Adds (or replaces) multiple request headers.

  See `put_header/3` for more information.

  ## Examples

      iex> req = Req.new()
      iex> req = Req.Request.put_headers(req, [{"accept", "text/html"}, {"accept-encoding", "gzip"}])
      iex> req.headers
      [{"accept", "text/html"}, {"accept-encoding", "gzip"}]
  """
  @spec put_headers(t(), [{binary(), binary()}]) :: t()
  def put_headers(%Req.Request{} = request, headers) do
    for {key, value} <- headers, reduce: request do
      acc -> put_header(acc, key, value)
    end
  end

  @doc """
  Adds a request header (`key`) unless already present.

  See `put_header/3` for more information.

  ## Examples

      iex> req =
      ...>   Req.new()
      ...>   |> Req.Request.put_new_header("accept", "application/json")
      ...>   |> Req.Request.put_new_header("accept", "application/html")
      iex> req.headers
      [{"accept", "application/json"}]
  """
  @spec put_new_header(t(), binary(), binary()) :: t()
  def put_new_header(%Req.Request{} = request, key, value)
      when is_binary(key) and is_binary(value) do
    case get_header(request, key) do
      [] ->
        put_header(request, key, value)

      _ ->
        request
    end
  end

  @doc """
  Registers options to be used by a custom steps.

  Req ensures that all used options were previously registered which helps
  finding accidentally mistyped option names. If you're adding custom steps
  that are accepting options, call this function to register them.

  ## Examples

      iex> Req.request!(urll: "https://httpbin.org")
      ** (ArgumentError) unknown option :urll. Did you mean :url?

      iex> Req.new(bas_url: "https://httpbin.org")
      ** (ArgumentError) unknown option :bas_url. Did you mean :base_url?

      req =
        Req.new(base_url: "https://httpbin.org")
        |> Req.Request.register_options([:foo])

      Req.get!(req, url: "/status/201", foo: :bar).status
      #=> 201
  """
  def register_options(%Req.Request{} = request, options) when is_list(options) do
    update_in(request.registered_options, &MapSet.union(&1, MapSet.new(options)))
  end

  @doc """
  Runs a request pipeline.

  Returns `{:ok, response}` or `{:error, exception}`.
  """
  def run(request) do
    run_request(request)
  end

  @doc """
  Runs a request pipeline and returns a response or raises an error.

  See `run/1` for more information.
  """
  def run!(request) do
    case run(request) do
      {:ok, response} -> response
      {:error, exception} -> raise exception
    end
  end

  defp run_request(%{current_request_steps: [step | rest]} = request) do
    step = Keyword.fetch!(request.request_steps, step)

    case step.(request) do
      %Req.Request{} = request ->
        run_request(%{request | current_request_steps: rest})

      {%Req.Request{halted: true}, response_or_exception} ->
        result(response_or_exception)

      {request, %Req.Response{} = response} ->
        run_response(request, response)

      {request, %{__exception__: true} = exception} ->
        run_error(request, exception)
    end
  end

  defp run_request(%{current_request_steps: []} = request) do
    case request.adapter.(request) do
      {request, %Req.Response{} = response} ->
        run_response(request, response)

      {request, %{__exception__: true} = exception} ->
        run_error(request, exception)

      other ->
        raise "expected adapter to return {request, response} or {request, exception}, " <>
                "got: #{inspect(other)}"
    end
  end

  defp run_response(request, response) do
    steps = request.response_steps

    {_request, response_or_exception} =
      Enum.reduce_while(steps, {request, response}, fn step, {request, response} ->
        case run_step(step, {request, response}) do
          {%Req.Request{halted: true} = request, response_or_exception} ->
            {:halt, {request, response_or_exception}}

          {request, %Req.Response{} = response} ->
            {:cont, {request, response}}

          {request, %{__exception__: true} = exception} ->
            {:halt, run_error(request, exception)}
        end
      end)

    result(response_or_exception)
  end

  defp run_error(request, exception) do
    steps = request.error_steps

    {_request, response_or_exception} =
      Enum.reduce_while(steps, {request, exception}, fn step, {request, exception} ->
        case run_step(step, {request, exception}) do
          {%Req.Request{halted: true} = request, response_or_exception} ->
            {:halt, {request, response_or_exception}}

          {request, %{__exception__: true} = exception} ->
            {:cont, {request, exception}}

          {request, %Req.Response{} = response} ->
            {:halt, run_response(request, response)}
        end
      end)

    result(response_or_exception)
  end

  defp run_step({name, step}, state) when is_atom(name) and is_function(step, 1) do
    step.(state)
  end

  defp result(%Req.Response{} = response) do
    {:ok, response}
  end

  defp result(%{__exception__: true} = exception) do
    {:error, exception}
  end

  @doc false
  def validate_options(%Req.Request{} = request, options) do
    validate_options(options, request.registered_options)
  end

  def validate_options([{name, _value} | rest], registered) do
    if name in registered do
      validate_options(rest, registered)
    else
      case did_you_mean(Atom.to_string(name), registered) do
        {similar, score} when score > 0.8 ->
          raise ArgumentError, "unknown option #{inspect(name)}. Did you mean :#{similar}?"

        _ ->
          raise ArgumentError, "unknown option #{inspect(name)}"
      end
    end
  end

  def validate_options([], _registered) do
    :ok
  end

  defp did_you_mean(option, registered) do
    registered
    |> Enum.map(&to_string/1)
    |> Enum.reduce({nil, 0}, &max_similar(&1, option, &2))
  end

  defp max_similar(option, registered, {_, current} = best) do
    score = String.jaro_distance(option, registered)
    if score < current, do: best, else: {option, score}
  end

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(request, opts) do
      open = color("%Req.Request{", :map, opts)
      sep = color(",", :map, opts)
      close = color("}", :map, opts)

      list = [
        method: request.method,
        url: request.url,
        headers: request.headers,
        body: request.body,
        options: request.options,
        registered_options: request.registered_options,
        halted: request.halted,
        adapter: request.adapter,
        request_steps: request.request_steps,
        response_steps: request.response_steps,
        error_steps: request.error_steps,
        private: request.private
      ]

      fun = fn
        {:url, value}, opts ->
          key = color("url:", :atom, opts)

          doc =
            concat(["URI.parse(", color("\"" <> URI.to_string(value) <> "\"", :string, opts), ")"])

          concat(key, concat(" ", doc))

        {key, value}, opts ->
          Inspect.List.keyword({key, value}, opts)
      end

      container_doc(open, list, close, opts, fun, separator: sep, break: :strict)
    end
  end
end
