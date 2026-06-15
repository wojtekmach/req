defmodule Req.Request do
  @moduledoc ~S"""
  The low-level API and the request struct.

  Req is composed of:

    * `Req` - the high-level API

    * `Req.Request` - the low-level API and the request struct (you're here!)

    * `Req.Steps` - the collection of built-in steps

    * `Req.Test` - the testing conveniences

  The low-level API and the request struct is the foundation of Req's extensibility. Virtually all
  of the functionality is broken down into individual pieces - steps. Req works by running the
  request struct through these steps. You can easily reuse or rearrange built-in steps or write new
  ones.

  To make using custom steps by others even easier, they can be packaged up into plugins.
  See ["Writing Plugins"](#module-writing-plugins) section for more information.

  ## The Low-level API

  Most Req users would use it like this:

      Req.get!("https://api.github.com/repos/wojtekmach/req").body["description"]
      #=> "Req is a batteries-included HTTP client for Elixir."

  Here is the equivalent using the low-level API:

      url = "https://api.github.com/repos/wojtekmach/req"

      req =
        Req.Request.new(method: :get, url: url)
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

      {req, resp} = Req.Request.run_request(req)
      resp.body["description"]
      #=> "Req is a batteries-included HTTP client for Elixir."

  By putting the request pipeline yourself you have precise control of exactly what is running and in what order.

  ## The Request Struct

  Public fields are:

    * `:method` - the HTTP request method.

    * `:url` - the HTTP request URL.

    * `:headers` - the HTTP request headers. The header names should be downcased.
      See also "Headers" section in `Req` module documentation.

    * `:body` - the HTTP request body.

      Can be one of:

        * `iodata` - eagerly send request body

        * `enumerable` - stream request body

        * `req_body_fun` - stream request body chunks from a 1-arity function.
          The function receives the request (as accumulator).

          It should return one of:

            * `{:data, chunk, request}` - emit request body `chunk`.

            * `{:done, request}` - request body is done.

            * `{:halt, request}` - cancel request. On HTTP/1, this closes the connection.

          `req_body_fun` requires Finch main.

    * `:into` - where to send the response body. It can be one of:

        * `nil` - (default) read the whole response body and store it in the `response.body`
          field.

        * `fun` - (deprecated) stream response body using a function. Deprecated in favour of
          `Req.stream/4`. The first argument is a `{:data, data}` tuple containing the chunk of
          the response body. The second argument is a `{request, response}` tuple. To continue
          streaming chunks, return `{:cont, {req, resp}}`. To cancel, return `{:halt, {req, resp}}`.
          For example:

              into: fn {:data, data}, {req, resp} ->
                IO.puts(data)
                {:cont, {req, resp}}
              end

        * `collectable` - stream response body into a `t:Collectable.t/0`. For example:

              into: File.stream!("path")

          Note that the collectable is only used, if the response status is 200. In other cases,
          the body is accumulated and processed as usual.

    * `:assigns` is a place for user data. It's commonly used when streaming response body with
      `into: fun` or when using application-specific custom steps.

    * `:options` - the options to be used by steps. The exact representation of options is private.
      Calling `request.options[key]`, `put_in(request.options[key], value)`, and
      `update_in(request.options[key], fun)` is allowed. `get_option/3` and `delete_option/2`
      are also available for additional ways to manipulate the internal representation.

    * `:halted` - whether the request pipeline is halted. See `halt/2`.

    * `:adapter` - a request step that makes the actual HTTP request. Defaults to
      `Req.Steps.run_finch/1`. See ["Adapter"](#module-adapter) section below for more information.

    * `:request_steps` - the list of request steps

    * `:response_steps` - the list of response steps

    * `:error_steps` - the list of error steps

    * `:private` - a map reserved for libraries and frameworks to use.  The keys must be atoms.
      Prefix the keys with the name of your project to avoid any future conflicts. The `req_`
      prefix is reserved for Req.

  ## Steps

  Req has three types of steps: request, response, and error.

  Request steps are used to refine the data that will be sent to the server.

  After making the actual HTTP request, we'll either get a HTTP response or an error.
  The request, along with the response or error, will go through response or
  error steps, respectively.

  Nothing is actually executed until we run the pipeline with `Req.Request.run_request/1`.

  ### Request Steps

  A **request step** (`t:request_step/0`) is a function that accepts a `request` and returns one
  of the following:

    * A `request`.

    * A `{request, response_or_error}` tuple. In this case no further request steps are executed
      and the return value goes through response or error steps.

  #### Examples

  A request step that adds a `user-agent` header if it's not there already:

      def put_default_headers(request) do
        Req.Request.put_new_header(request, "user-agent", "req")
      end

  The next is a request step that reads the response from cache if available. Note how, if the
  cached response is available, this step returns a `{request, response}` tuple so that the
  request doesn't actually go through:

      def read_from_cache(request) do
        case ResponseCache.fetch(request) do
          {:ok, response} -> {request, response}
          :error -> request
        end
      end

  ### Response and Error Steps

  A response step (`t:response_step/0`) is a function that accepts a `{request, response}` tuple
  and returns one of the following:

    * A `{request, response}` tuple.

    * A `{request, exception}` tuple. In that case, no further response steps are executed but the
      exception goes through error steps.

  Similarly, an error step is a function that accepts a `{request, exception}` tuple and returns one
  of the following:

    * A `{request, exception}` tuple

    * A `{request, response}` tuple. In that case, no further error steps are executed but the
      response goes through response steps.

  Examples:

      def decode({request, response}) do
        case Req.Response.get_header(response, "content-type") do
          ["application/json" <> _] ->
            {request, update_in(response.body, &Jason.decode!/1)}

          [] ->
            {request, response}
        end
      end

      def log_error({request, exception}) do
        Logger.error(["#{request.method} #{request.uri}: ", Exception.message(exception)])
        {request, exception}
      end

  ### Halting

  Any step can call `halt/2` to halt the pipeline. This prevents any further steps
  from being invoked.

  Examples:

      def circuit_breaker(request) do
        if CircuitBreaker.open?() do
          Req.Request.halt(request, RuntimeError.exception("circuit breaker is open"))
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
      # > accept-encoding: br, gzip
      # > user-agent: req/0.3.0-dev
      # < date: Wed, 11 May 2022 11:10:47 GMT
      # < content-type: application/json
      # ...
      200

      req = Req.new() |> PrintHeaders.attach(print_headers: true)
      Req.get!(req, url: "https://httpbin.org/json").status
      # Outputs:
      # > accept-encoding: br, gzip
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

  As noted in the ["Request Steps"](#module-request-steps) section, a request step besides returning the request,
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
            headers = for {name, value} <- headers, do: {String.downcase(name, :ascii), value}
            response = %Req.Response{status: status, headers: headers, body: body}
            {request, response}

          {:error, reason} ->
            {request, RuntimeError.exception(inspect(reason))}
        end
      end

      Req.get!("https://api.github.com/repos/wojtekmach/req", adapter: hackney).body["description"]
      #=> "Req is a batteries-included HTTP client for Elixir."

  """

  @typedoc """
  A function for streaming request body chunks.
  """
  @type req_body_fun() ::
          (t() -> {:data, binary(), t()} | {:done, t()} | {:halt, t()})

  @typedoc """
  The request struct.
  """
  @type t() :: %Req.Request{
          method: atom(),
          url: URI.t(),
          headers: %{optional(binary()) => [binary()]},
          body: iodata() | Enumerable.t() | req_body_fun() | nil,
          into:
            nil
            | iodata()
            | ({:data, binary()}, {t(), Req.Response.t()} ->
                 {:cont | :halt, {t, Req.Response.t()}})
            | Collectable.t(),
          stream:
            nil
            | (binary(), Req.Response.t(), acc :: term() ->
                 {Req.Response.t(), acc :: term()}),
          options: options(),
          assigns: map(),
          halted: boolean(),
          adapter: request_step(),
          request_steps: [{name :: atom(), request_step()}],
          response_steps: [{name :: atom(), response_step()}],
          error_steps: [{name :: atom(), error_step()}],
          private: map()
        }

  @typedoc """
  A request step is a function that takes a request and returns a request or a tuple of request
  and response/exception.

  The function can be an anonymous function, or a `{module, function, args}` tuple. In the latter
  case, the step is invoked as `apply(module, function, [request | args])`.

  See also the ["Request Steps"](#module-request-steps) section in the module documentation.
  """
  @typedoc since: "0.5.1"
  @type request_step() ::
          (t() -> t() | {t(), Req.Response.t() | Exception.t()}) | {module(), atom(), [term()]}

  @typedoc """
  A response step is a function that takes a request/response tuple and returns a request/response
  or a request/exception tuple.

  The function can be an anonymous function, or a `{module, function, args}` tuple. In the latter
  case, the step is invoked as `apply(module, function, [request | args])`.

  See also the ["Response and Error Steps"](#module-response-and-error-steps) section in the
  module documentation.
  """
  @typedoc since: "0.5.1"
  @type response_step() ::
          ({t(), Req.Response.t()} -> {t(), Req.Response.t() | Exception.t()})
          | {module(), atom(), [term()]}

  @typedoc """
  An error step is a function that takes a request/exception tuple and returns a request/response
  or a request/exception tuple.

  The function can be an anonymous function, or a `{module, function, args}` tuple. In the latter
  case, the step is invoked as `apply(module, function, [request | args])`.

  See also the ["Response and Error Steps"](#module-response-and-error-steps) section in the
  module documentation.
  """
  @typedoc since: "0.5.1"
  @type error_step() ::
          ({t(), Exception.t()} -> {t(), Req.Response.t() | Exception.t()})
          | {module(), atom(), [term()]}

  @typep options() :: term()

  defstruct method: :get,
            url: URI.parse(""),
            headers: Req.Fields.new([]),
            body: nil,
            options: %{},
            assigns: %{},
            halted: false,
            adapter: &Req.Steps.run_finch/1,
            request_steps: [],
            response_steps: [],
            error_steps: [],
            private: %{},
            registered_options: MapSet.new(),
            current_request_steps: [],
            into: nil,
            stream: nil,
            async: nil

  @doc """
  Returns a new request struct.

  ## Options

    * `:method` - the request method, defaults to `:get`.

    * `:url` - the request URL.

    * `:headers` - the request headers, defaults to `[]`.

    * `:body` - the request body, defaults to `nil`.

    * `:assigns` - shared user data as a map.

    * `:adapter` - the request adapter, defaults to calling [`run_finch`](`Req.Steps.run_finch/1`).

  ## Examples

      iex> req = Req.Request.new(url: "https://api.github.com/repos/wojtekmach/req")
      iex> {req, resp} = Req.Request.run_request(req)
      iex> req.url.host
      "api.github.com"
      iex> resp.status
      200
  """
  @spec new(keyword()) :: t()
  def new(options \\ []) do
    options =
      options
      |> Keyword.validate!([:method, :url, :headers, :body, :adapter, :options, :assigns])
      |> Keyword.update(:url, URI.new!(""), &URI.parse/1)
      |> Keyword.update(:headers, Req.Fields.new([]), &Req.Fields.new_without_normalize/1)
      |> Keyword.update(:options, %{}, &Map.new/1)
      |> Keyword.update(:assigns, %{}, &Map.new/1)

    struct!(__MODULE__, options)
  end

  @doc """
  Sets the value `value` for the option `name`.

  See also `put_new_option/3`, `merge_options/2`, and `merge_new_options/2`.

  ## Examples

      iex> req = Req.Request.new() |> Req.Request.register_options([:a])
      iex> req.options
      %{}
      iex> req = Req.Request.put_option(req, :a, 1)
      iex> req.options
      %{a: 1}

      iex> req = Req.Request.new()
      iex> Req.Request.put_option(req, :b, 2)
      ** (ArgumentError) unknown option :b
  """
  @spec put_option(t(), atom(), term()) :: t()
  def put_option(%Req.Request{} = request, key, value) when is_atom(key) do
    validate_options(request, [{key, value}])
    put_in(request.options[key], value)
  end

  @doc """
  Sets the value `value` for the option `name` unless option is already set.

  See also `put_option/3`, `merge_options/2`, and `merge_new_options/2`.

  ## Examples

      iex> req = Req.Request.new() |> Req.Request.register_options([:a])
      iex> req.options
      %{}
      iex> req = Req.Request.put_new_option(req, :a, 1)
      iex> req.options
      %{a: 1}
      iex> req = Req.Request.put_new_option(req, :a, 2)
      iex> req.options
      %{a: 1}

      iex> req = Req.Request.new()
      iex> Req.Request.put_new_option(req, :b, 2)
      ** (ArgumentError) unknown option :b
  """
  @spec put_new_option(t(), atom(), term()) :: t()
  def put_new_option(%Req.Request{} = request, key, value) when is_atom(key) do
    validate_options(request, [{key, value}])
    update_in(request.options, &Map.put_new(&1, key, value))
  end

  @doc """
  Gets the value for the option `key`.

  See also `fetch_option!/2`.

  ## Examples

      iex> req = Req.Request.new(options: [a: 1])
      iex> Req.Request.get_option(req, :a)
      1
      iex> Req.Request.get_option(req, :b)
      nil
      iex> Req.Request.get_option(req, :b, 0)
      0
  """
  @spec get_option(t(), atom(), term()) :: term()
  def get_option(request, key, default \\ nil) when is_atom(key) do
    Map.get(request.options, key, default)
  end

  @doc """
  Gets the value for the option `key`.

  This is useful if the default value is very expensive to calculate or generally
  difficult to setup and teardown again.

  See also `get_option/3`.

  ## Examples

      iex> req = Req.Request.new(options: [a: 1])
      iex> fun = fn ->
      ...>   # some expensive operation here
      ...>   42
      ...> end
      iex> Req.Request.get_option_lazy(req, :a, fun)
      1
      iex> Req.Request.get_option_lazy(req, :b, fun)
      42
  """
  @spec get_option_lazy(t(), atom(), (-> term())) :: term()
  def get_option_lazy(request, key, fun) when is_function(fun, 0) do
    Map.get_lazy(request.options, key, fun)
  end

  @doc """
  Fetches the value for the option `key`.

  See also `get_option/3`.

  ## Examples

      iex> req = Req.Request.new(options: [a: 1])
      iex> Req.Request.fetch_option(req, :a)
      {:ok, 1}
      iex> Req.Request.fetch_option(req, :b)
      :error
  """
  @spec fetch_option(t(), atom()) :: {:ok, term()} | :error
  def fetch_option(request, key) when is_atom(key) do
    Map.fetch(request.options, key)
  end

  @doc """
  Fetches the value for the option `key` or raises if it's not set.

  See also `get_option/3`.

  ## Examples

      iex> req = Req.Request.new(options: [a: 1])
      iex> Req.Request.fetch_option!(req, :a)
      1
      iex> Req.Request.fetch_option!(req, :b)
      ** (KeyError) option :b is not set
  """
  @spec fetch_option!(t(), atom()) :: term()
  def fetch_option!(request, key) when is_atom(key) do
    case Map.fetch(request.options, key) do
      {:ok, value} ->
        value

      :error ->
        raise KeyError,
          term: request.options,
          key: key,
          message: "option #{inspect(key)} is not set"
    end
  end

  @doc """
  Deletes the given option `key`.

  ## Examples

      iex> req = Req.Request.new(options: [a: 1])
      iex> Req.Request.get_option(req, :a)
      1
      iex> req = Req.Request.delete_option(req, :a)
      iex> Req.Request.get_option(req, :a)
      nil
  """
  @spec delete_option(t(), atom()) :: t()
  def delete_option(request, key) when is_atom(key) do
    update_in(request.options, &Map.delete(&1, key))
  end

  @doc """
  Drops the given `keys` from options.

  ## Examples

      iex> req = Req.Request.new(options: [a: 1, b: 2, c: 3])
      iex> req = Req.Request.drop_options(req, [:a, :b])
      iex> Req.Request.get_option(req, :a)
      nil
      iex> Req.Request.get_option(req, :c)
      3
  """
  @spec drop_options(t(), [atom()]) :: t()
  def drop_options(request, keys) when is_list(keys) do
    update_in(request.options, &Map.drop(&1, keys))
  end

  @doc """
  Gets the value for a specific private `key`.
  """
  @spec get_private(t(), atom(), default) :: term() | default when default: var
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
  @spec update_private(t(), key :: atom(), default :: term(), (term() -> term())) :: t()
  def update_private(request, key, default, fun) when is_atom(key) and is_function(fun, 1) do
    update_in(request.private, &Map.update(&1, key, default, fun))
  end

  @doc """
  Assigns a private `key` to `value`.
  """
  @spec put_private(t(), atom(), term()) :: t()
  def put_private(request, key, value) when is_atom(key) do
    put_in(request.private[key], value)
  end

  @doc false
  @deprecated "Use Req.Request.halt/2 instead"
  def halt(request) do
    %{request | halted: true}
  end

  @doc """
  Halts the request pipeline preventing any further steps from executing.

  This function returns an updated request and the response or exception that caused the halt.
  It's perfect when used in a request step to stop the pipeline.

  See the ["Halting"](#module-halting) section in the module documentation for more information.

  ## Examples

      Req.Request.prepend_request_steps(request, circuit_breaker: fn request ->
        if CircuitBreaker.open?() do
          Req.Request.halt(request, RuntimeError.exception("circuit breaker is open"))
        else
          request
        end
      end)

  """
  @spec halt(t(), response_or_exception) :: {t(), response_or_exception}
        when response_or_exception: Req.Response.t() | Exception.t()
  def halt(request, response_or_exception)

  def halt(%Req.Request{} = request, %Req.Response{} = response) do
    {put_in(request.halted, true), response}
  end

  def halt(%Req.Request{} = request, %_{__exception__: true} = exception) do
    {put_in(request.halted, true), exception}
  end

  @doc """
  Appends **request steps** to the existing request steps.

  See the ["Request Steps"](#module-request-steps) section in the module documentation
  for more information.

  ## Examples

      Req.Request.append_request_steps(request,
        noop: fn request -> request end,
        inspect: &IO.inspect/1
      )
  """
  @spec append_request_steps(t(), keyword(request_step())) :: t()
  def append_request_steps(request, steps) do
    %{
      request
      | request_steps: request.request_steps ++ steps,
        current_request_steps: request.current_request_steps ++ Keyword.keys(steps)
    }
  end

  @doc """
  Prepends **request steps** to the existing request steps.

  See the ["Request Steps"](#module-request-steps) section in the module documentation
  for more information.

  ## Examples

      Req.Request.prepend_request_steps(request,
        noop: fn request -> request end,
        inspect: &IO.inspect/1
      )
  """
  @spec prepend_request_steps(t(), keyword(request_step())) :: t()
  def prepend_request_steps(request, steps) do
    %{
      request
      | request_steps: steps ++ request.request_steps,
        current_request_steps: Keyword.keys(steps) ++ request.current_request_steps
    }
  end

  @doc """
  Appends **response steps** to the existing response steps.

  See the ["Response and Error Steps"](#module-response-and-error-steps) section in the
  module documentation for more information.

  ## Examples

      Req.Request.append_response_steps(request,
        noop: fn {request, response} -> {request, response} end,
        inspect: &IO.inspect/1
      )
  """
  @spec append_response_steps(t(), keyword(response_step())) :: t()
  def append_response_steps(request, steps) do
    %{
      request
      | response_steps: request.response_steps ++ steps
    }
  end

  @doc """
  Prepends **response steps** to the existing response steps.

  See the ["Response and Error Steps"](#module-response-and-error-steps) section in the
  module documentation for more information.

  ## Examples

      Req.Request.prepend_response_steps(request,
        noop: fn {request, response} -> {request, response} end,
        inspect: &IO.inspect/1
      )
  """
  @spec prepend_response_steps(t(), keyword(response_step())) :: t()
  def prepend_response_steps(request, steps) do
    %{
      request
      | response_steps: steps ++ request.response_steps
    }
  end

  @doc """
  Appends **error steps** to the existing error steps.

  See the ["Response and Error Steps"](#module-response-and-error-steps) section in the
  module documentation for more information.

  ## Examples

      Req.Request.append_error_steps(request,
        noop: fn {request, exception} -> {request, exception} end,
        inspect: &IO.inspect/1
      )
  """
  @spec append_error_steps(t(), keyword(error_step())) :: t()
  def append_error_steps(request, steps) do
    %{
      request
      | error_steps: request.error_steps ++ steps
    }
  end

  @doc """
  Prepends **error steps** to the existing error steps.

  See the ["Response and Error Steps"](#module-response-and-error-steps) section in the
  module documentation for more information.

  ## Examples

      Req.Request.prepend_error_steps(request,
        noop: fn {request, exception} -> {request, exception} end,
        inspect: &IO.inspect/1
      )
  """
  @spec prepend_error_steps(t(), keyword(error_step())) :: t()
  def prepend_error_steps(request, steps) do
    %{
      request
      | error_steps: steps ++ request.error_steps
    }
  end

  @doc false
  def prepare(%{request_steps: [{_name, step} | steps]} = request) do
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

      iex> req = Req.new(auth: {:basic, "alice:secret"}, http_errors: :raise)
      iex> req = Req.Request.merge_options(req, auth: {:bearer, "abcd"}, base_url: "https://example.com")
      iex> req.options[:auth]
      {:bearer, "abcd"}
      iex> req.options[:http_errors]
      :raise
      iex> req.options[:base_url]
      "https://example.com"
  """
  @spec merge_options(t(), keyword()) :: t()
  def merge_options(%Req.Request{} = request, options) when is_list(options) do
    # TODO: remove on v0.5
    deprecated = [:method, :url, :headers, :body, :adapter]
    keys = deprecated -- Keyword.keys(options)

    options =
      case deprecated -- keys do
        [] ->
          options

        deprecated ->
          IO.warn(
            "Passing " <>
              Enum.map_join(deprecated, "/", &inspect/1) <>
              " is deprecated, use Req.merge/2 instead."
          )

          Keyword.drop(options, deprecated)
      end

    validate_options(request, options)
    update_in(request.options, &Map.merge(&1, Map.new(options)))
  end

  @doc """
  Merges given options into the request unless they are already set.

  ## Examples

      iex> req = Req.new(auth: {:basic, "alice:secret"})
      iex> req.options
      %{auth: {:basic, "alice:secret"}}
      iex> req = Req.Request.merge_new_options(req, auth: {:bearer, "abcd"}, base_url: "https://example.com")
      iex> req.options
      %{auth: {:basic, "alice:secret"}, base_url: "https://example.com"}

      iex> req = Req.new()
      iex> Req.Request.merge_new_options(req, foo: :bar)
      ** (ArgumentError) unknown option :foo
  """
  @spec merge_new_options(t(), keyword()) :: t()
  def merge_new_options(%Req.Request{} = request, options) when is_list(options) do
    validate_options(request, options)
    update_in(request.options, &Map.merge(&1, Map.new(options), fn _k, v1, _v2 -> v1 end))
  end

  @doc """
  Returns the values of the header specified by `name`.

  See also "Headers" section in `Req` module documentation.

  ## Examples

      iex> req = Req.new(headers: [{"accept", "application/json"}])
      iex> Req.Request.get_header(req, "accept")
      ["application/json"]
      iex> Req.Request.get_header(req, "x-unknown")
      []

  """
  @spec get_header(t(), binary()) :: [binary()]
  def get_header(%Req.Request{} = req, name) when is_binary(name) do
    Req.Fields.get_values(req.headers, name)
  end

  @doc """
  Sets the header `name` to `value`.

  The value can be a binary or a list of binaries,

  If the header was previously set, its value is overwritten.

  See also "Headers" section in `Req` module documentation.

  ## Examples

      iex> req = Req.new()
      iex> Req.Request.get_header(req, "accept")
      []
      iex> req = Req.Request.put_header(req, "accept", "application/json")
      iex> Req.Request.get_header(req, "accept")
      ["application/json"]

  """
  @spec put_header(t(), binary(), binary()) :: t()
  def put_header(%Req.Request{} = request, name, value)
      when is_binary(name) and is_binary(value) do
    update_in(request.headers, &Req.Fields.put(&1, name, value))
  end

  @doc """
  Adds (or replaces) multiple request headers.

  See `put_header/3` for more information.

  ## Examples

      iex> req = Req.new()
      iex> req = Req.Request.put_headers(req, [{"accept", "text/html"}, {"accept-encoding", "gzip"}])
      iex> Req.Request.get_header(req, "accept")
      ["text/html"]
      iex> Req.Request.get_header(req, "accept-encoding")
      ["gzip"]
  """
  @spec put_headers(t(), [{binary(), binary()}]) :: t()
  def put_headers(%Req.Request{} = request, headers) do
    for {name, value} <- headers, reduce: request do
      acc -> put_header(acc, name, value)
    end
  end

  @doc """
  Adds a request header `name` unless already present.

  See `put_header/3` for more information.

  ## Examples

      iex> req =
      ...>   Req.new()
      ...>   |> Req.Request.put_new_header("accept", "application/json")
      ...>   |> Req.Request.put_new_header("accept", "application/html")
      iex> Req.Request.get_header(req, "accept")
      ["application/json"]
  """
  @spec put_new_header(t(), binary(), binary()) :: t()
  def put_new_header(%Req.Request{} = request, name, value)
      when is_binary(name) and is_binary(value) do
    update_in(request.headers, &Req.Fields.put_new(&1, name, value))
  end

  @doc """
  Deletes the header given by `name`.

  All occurrences of the header are deleted, in case the header is repeated multiple times.

  See also "Headers" section in `Req` module documentation.

  ## Examples

      iex> Req.Request.get_header(req, "cache-control")
      ["max-age=600", "no-transform"]
      iex> req = Req.Request.delete_header(req, "cache-control")
      iex> Req.Request.get_header(req, "cache-control")
      []

  """
  @spec delete_header(t(), binary()) :: t()
  def delete_header(%Req.Request{} = request, name) when is_binary(name) do
    update_in(request.headers, &Req.Fields.delete(&1, name))
  end

  @doc """
  Registers options to be used by custom steps.

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
  @spec register_options(t(), [atom()]) :: t()
  def register_options(%Req.Request{} = request, options) when is_list(options) do
    update_in(request.registered_options, &MapSet.union(&1, MapSet.new(options)))
  end

  @doc deprecated: "Use Req.Request.run_request/1 instead"
  def run(request) do
    case run_request(request) do
      {_request, %Req.Response{} = response} ->
        {:ok, response}

      {_request, exception} ->
        {:error, exception}
    end
  end

  @doc deprecated: "Use Req.Request.run_request/1 instead"
  def run!(request) do
    case run_request(request) do
      {_request, %Req.Response{} = response} ->
        response

      {_request, exception} ->
        raise exception
    end
  end

  @doc false
  def stream_request(%Req.Request{current_request_steps: [step | rest]} = req, acc) do
    step = Keyword.fetch!(req.request_steps, step)
    %Req.Request{} = req = run_step(step, req)
    stream_request(%{req | current_request_steps: rest}, acc)
  end

  def stream_request(%Req.Request{current_request_steps: []} = req, acc) do
    req = put_in(req.private[:req_stream_acc], acc)

    adapter =
      case req.adapter do
        # :httpc -> &Req.HTTPC.run/1
        :finch -> &Req.Steps.run_finch/1
        other -> other
      end

    case run_step(adapter, req) do
      {_req, %Req.Response{} = resp} ->
        {:ok, resp, resp.private[:req_stream_acc]}

      {req, %{__exception__: true} = exception} ->
        # The stream error carries the request in `resp.request` so in-stream retries/redirects
        # thread it back out; the adapter's error gives a bare request, so wrap it.
        {:error, %{Req.Response.new() | request: req}, exception, req.private[:req_stream_acc]}
    end
  end

  @doc """
  Runs the request pipeline.

  Returns `{request, response}` or `{request, exception}`.

  ## Examples

      iex> req = Req.Request.new(url: "https://api.github.com/repos/wojtekmach/req")
      iex> {request, response} = Req.Request.run_request(req)
      iex> request.url.host
      "api.github.com"
      iex> response.status
      200
  """
  @spec run_request(t()) :: {t(), Req.Response.t() | Exception.t()}
  def run_request(request)

  # Adapters always drive `request.stream`. When the caller did not ask for streaming
  # (no `Req.stream/4`, no `:into`), install a buffering stream that accumulates the body and
  # materializes `response.body` at `:eof`. It is installed before the request steps run so that
  # steps like `decode_body`, `decompress_body`, `redirect`, `retry`, and `expect` — which are
  # all stream wrappers — can wrap it. The `req_buffer` marker tells `decode_body` to decode the
  # full body at `:eof` rather than stream events to the caller.
  def run_request(%{stream: nil, into: nil} = request) do
    request =
      %{request | stream: &buffer_stream/3}
      |> put_private(:req_buffer, true)
      |> put_private(:req_stream_acc, [])

    drop_stream_private(run_request(request))
  end

  # `into:` a collectable streams the 200 response body into it; non-200 responses ignore the
  # collectable and are buffered (and decoded) like a normal response. Like the buffering stream,
  # it is installed before the request steps so `checksum` and friends wrap it like any stream.
  # `req_buffer` lets `decode_body` decode the buffered non-200 body; collected bodies are not
  # binaries, so its `not is_binary(body)` guard already leaves them alone.
  def run_request(%{stream: nil, into: into} = request)
      when into != :self and not is_function(into, 2) do
    request =
      %{request | into: nil, stream: collectable_stream(into)}
      |> put_private(:req_buffer, true)
      |> put_private(:req_stream_acc, :unset)

    drop_stream_private(run_request(request))
  end

  def run_request(%{stream: nil, into: :self} = request) do
    drop_stream_private(run_request(%{request | stream: &self_stream/3}))
  end

  def run_request(%{current_request_steps: [step | rest]} = request) do
    step = Keyword.fetch!(request.request_steps, step)

    case run_step(step, request) do
      %Req.Request{} = request ->
        run_request(%{request | current_request_steps: rest})

      {%Req.Request{halted: true} = request, response_or_exception} ->
        {request, response_or_exception}

      {request, %Req.Response{} = response} ->
        run_response(request, response)

      {request, %{__exception__: true} = exception} ->
        run_error(request, exception)
    end
  end

  def run_request(%{current_request_steps: []} = request) do
    request = put_into_stream(request)

    case run_step(request.adapter, request) do
      # `into: fun` returning `{:halt, _}` stops the stream via the `:req_halt` sentinel; the
      # accumulator holds the response to finish with.
      {request, :req_halt} ->
        {request, response} = finish_into_stream(request, nil)
        run_response(request, response)

      {request, %Req.Response{} = response} ->
        {request, response} = finish_into_stream(request, response)

        # The adapter threads request-body-fun mutations onto `request` (e.g. a halted body's
        # `put_private`), while in-stream retries/redirects thread their state (`req_retry_count`,
        # the redirected URL, ...) onto `response.request`. Neither alone is complete, so return
        # `response.request` merged with anything only `request` saw — the response's later view
        # wins on conflict. `into: fun` already restored its threaded request via
        # `finish_into_stream/2`; `into: :self` builds a response with no request.
        request =
          cond do
            request.private[:req_into_fun] ->
              request

            response.request ->
              %{response.request | private: Map.merge(request.private, response.request.private)}

            true ->
              request
          end

        run_response(request, response)

      {request, %{__exception__: true} = exception} ->
        run_error(request, exception)

      other ->
        raise "expected adapter to return {request, response} or {request, exception}, " <>
                "got: #{inspect(other)}"
    end
  end

  defp drop_stream_private({request, response_or_exception}) do
    request = update_in(request.private, &Map.drop(&1, [:req_buffer, :req_stream_acc]))
    {request, response_or_exception}
  end

  # The innermost `request.stream` for non-streaming requests: accumulate chunks as iodata and
  # materialize `response.body` on `:eof`.
  defp buffer_stream(:eof, resp, acc) do
    {:ok, %{resp | body: IO.iodata_to_binary(acc)}, acc}
  end

  defp buffer_stream(data, resp, acc) do
    {:ok, resp, [acc | data]}
  end

  defp self_stream(_data_or_eof, resp, acc) do
    {:ok, resp, acc}
  end

  defp collectable_stream(collectable) do
    fn data_or_eof, resp, acc ->
      collectable_chunk(data_or_eof, resp, start_collectable(acc, resp, collectable))
    end
  end

  defp start_collectable(:unset, %{status: 200}, collectable) do
    {acc, collector} = Collectable.into(collectable)
    {:collect, collector, acc}
  end

  defp start_collectable(:unset, _resp, _collectable) do
    {:buffer, []}
  end

  defp start_collectable(acc, _resp, _collectable) do
    acc
  end

  defp collectable_chunk(:eof, resp, {:collect, collector, acc}) do
    {:ok, %{resp | body: collector.(acc, :done)}, {:collect, collector, acc}}
  end

  defp collectable_chunk(:eof, resp, {:buffer, iodata}) do
    {:ok, %{resp | body: IO.iodata_to_binary(iodata)}, {:buffer, iodata}}
  end

  defp collectable_chunk(data, resp, {:collect, collector, acc}) do
    {:ok, resp, {:collect, collector, collector.(acc, {:cont, data})}}
  end

  defp collectable_chunk(data, resp, {:buffer, iodata}) do
    {:ok, resp, {:buffer, [iodata | data]}}
  end

  # Bridges the deprecated `into: fun` option onto `request.stream`, so streaming goes through a
  # single code path across all adapters. Runs after the request steps (so steps like `checksum`
  # have wrapped `into`) and before the adapter. The chunks are passed through raw (no decoding),
  # preserving the `into: fun` contract.
  defp put_into_stream(%{into: into} = request) when is_function(into, 2) do
    request =
      %{request | into: nil, stream: into_stream(into)}
      |> update_in_options(:decoders, false)
      |> put_private(:req_into_fun, true)

    # The callback threads `{req, resp}`, so the accumulator carries both; steps like `checksum`
    # accumulate state in the request's private during streaming and read it back afterwards.
    put_private(request, :req_stream_acc, {request, Req.Response.new()})
  end

  defp put_into_stream(request) do
    request
  end

  # After the adapter, restore the request threaded through the stream (carrying e.g. the running
  # checksum). On a normal finish the accumulator is on the response; on `:req_halt` it is on the
  # request (and also holds the response to finish with).
  defp finish_into_stream(request, response) do
    case request.private do
      %{req_into_fun: true} ->
        {threaded_request, threaded_response} =
          (response && response.private[:req_stream_acc]) || request.private[:req_stream_acc]

        {threaded_request, response || threaded_response}

      _ ->
        {request, response}
    end
  end

  # Adapts the 2-arity `into: fun` callback to the 3-arity `request.stream` contract. Status,
  # headers and trailers come from the wire (`adapter_resp`); the body is whatever the callback
  # accumulates into the response it threads. The accumulator is the threaded `{req, resp}`.
  # `{:halt, _}` stops via the `{:error, resp, :req_halt, acc}` sentinel, reusing the adapters'
  # error path; `run_request/1` turns it back into a successful response built from the accumulator.
  defp into_stream(into) do
    fn
      :eof, adapter_resp, {req, user_resp} ->
        {:ok, merge_into_resp(adapter_resp, user_resp), {req, user_resp}}

      data, adapter_resp, {req, user_resp} ->
        view = merge_into_resp(adapter_resp, user_resp)

        case into.({:data, data}, {req, view}) do
          {:cont, {req, user_resp}} ->
            {:ok, adapter_resp, {req, user_resp}}

          {:halt, {req, user_resp}} ->
            {:error, adapter_resp, :req_halt, {req, merge_into_resp(adapter_resp, user_resp)}}

          other ->
            raise ArgumentError,
                  "expected into: fun to return {:cont, {req, resp}} or {:halt, {req, resp}}, " <>
                    "got: #{inspect(other)}"
        end
    end
  end

  defp merge_into_resp(adapter_resp, user_resp) do
    %{
      user_resp
      | status: adapter_resp.status,
        headers: adapter_resp.headers,
        trailers: adapter_resp.trailers,
        request: adapter_resp.request
    }
  end

  defp update_in_options(request, key, value) do
    update_in(request.options, &Map.put(&1, key, value))
  end

  defp run_response(request, response) do
    steps = request.response_steps

    Enum.reduce_while(steps, {request, response}, fn {_name, step}, {request, response} ->
      case run_step(step, {request, response}) do
        {%Req.Request{halted: true} = request, response_or_exception} ->
          {:halt, {request, response_or_exception}}

        {request, %Req.Response{} = response} ->
          {:cont, {request, response}}

        {request, %{__exception__: true} = exception} ->
          {:halt, run_error(request, exception)}
      end
    end)
  end

  defp run_error(request, exception) do
    steps = request.error_steps

    Enum.reduce_while(steps, {request, exception}, fn {_name, step}, {request, exception} ->
      case run_step(step, {request, exception}) do
        {%Req.Request{halted: true} = request, response_or_exception} ->
          {:halt, {request, response_or_exception}}

        {request, %{__exception__: true} = exception} ->
          {:cont, {request, exception}}

        {request, %Req.Response{} = response} ->
          {:halt, run_response(request, response)}
      end
    end)
  end

  defp run_step(step, state) when is_function(step, 1) do
    step.(state)
  end

  defp run_step({mod, fun, args}, state) when is_atom(mod) and is_atom(fun) and is_list(args) do
    apply(mod, fun, [state | args])
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

      headers =
        if unquote(Req.MixProject.legacy_headers_as_lists?()) do
          for {name, value} <- request.headers do
            if Req.Fields.ensure_name_downcase(name) == "authorization" do
              [scheme, value] = String.split(value, " ", parts: 2)
              {name, scheme <> " " <> redact(value)}
            else
              {name, value}
            end
          end
        else
          for {name, values} <- request.headers, into: %{} do
            if Req.Fields.ensure_name_downcase(name) == "authorization" do
              [value] = values
              [scheme, value] = String.split(value, " ", parts: 2)
              {name, [scheme <> " " <> redact(value)]}
            else
              {name, values}
            end
          end
        end

      list = [
        method: request.method,
        url: request.url,
        headers: headers,
        body: request.body,
        assigns: request.assigns,
        options:
          Map.new(request.options, fn {name, value} ->
            {name, redact_option(name, value)}
          end),
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
            concat([
              "URI.parse(",
              color("\"" <> URI.to_string(value) <> "\"", :string, opts),
              ")"
            ])

          concat(key, concat(" ", doc))

        {key, value}, opts ->
          Inspect.List.keyword({key, value}, opts)
      end

      container_doc(open, list, close, opts, fun, separator: sep, break: :strict)
    end

    defp redact_option(:auth, {:bearer, bearer}) do
      {:bearer, redact(bearer)}
    end

    defp redact_option(:auth, {:basic, userinfo}) do
      {:basic, redact(userinfo)}
    end

    # TODO: remove on 1.0/1.1?
    defp redact_option(:auth, {username, password})
         when is_binary(username) and is_binary(password) do
      {redact(username), redact(password)}
    end

    defp redact_option(:aws_sigv4, options) do
      Enum.map(options, fn {name, value} ->
        if name in [:access_key_id, :secret_access_key] do
          {name, redact(value)}
        else
          {name, value}
        end
      end)
    end

    defp redact_option(name, value) when is_atom(name) do
      value
    end

    defp redact(string) do
      len = String.length(string)

      if len < 4 do
        String.duplicate("*", len)
      else
        String.slice(string, 0, 3) <> String.duplicate("*", len - 3)
      end
    end
  end
end
