defmodule Breaker do
  @moduledoc """
  A circuit-breaker wrapped around `HTTPoison` to make requests to external
  resources and help your application gracefully fail.

  Defines a function for each HTTP method (ie `Breaker.get()`) that returns a
  Task that will execute the HTTP request (using `HTTPoison`) and record the
  response in the circuit breaker.
  """

  use GenServer

  @typedoc """
  A Map containing information for the circuit.

  It holds:

  * `url`: The base url associated with the breaker.
  * `headers`: Additional headers to use when making requests.
  * `timeout`: The time to wait (in ms) before giving up on a request.
  * `open`: The current state of the breaker.
  * `error_threshold`: The percent of requests allowed to fail, as a float.
  * `window_length`: The number of buckets in the health calculation window.
  * `bucket_length`: The number of milliseconds for each bucket.
  * `sum`: The current sum of total requests and errors.
  * `window`: The window of buckets adding up to `sum`.
  """
  @type t :: %{
    url: String.t,
    headers: [...],
    timeout: number,
    open: boolean,
    error_threshold: float,
    window_length: number,
    bucket_length: number,
    sum: %{total: number, errors: number},
    window: [%{total: number, errors: number}]
  }

  ### Public API

  @doc """
  Create a new circuit-breaker with the given options keyword list.

  ## Parameters: ##

  * `options`: A Keyword list of options, described below.
  * `name`: The name to register the GenServer.

  ## Available options are: ##

  * `url`: The base url to use for the breaker. This is ideally a single
    external resource, complete with protocal, domain name, port, and an
    optional subpath. Required.
  * `headers`: A keyword list of headers, passed to `HTTPoison`.
  * `timeout`: How long to wait until considering the request timed out.
    Passed to HTTPoison.
  * `open`: Boolean defining if the circuit is broken. Defaults to false.
  * `error_threshold`: The percent of requests allowed to fail, as a float.
    Defaults to 0.05 (5%)
  * `window_length`: The number of buckets in the health calculation window.
    Defaults to 10.
  * `bucket_length`: The number of milliseconds for each bucket. Defaults to
    1000, meaning health is caluculated over the past 10 seconds using the
    defaults.

  ## Examples: ##

      iex> options = [url: "http://httpbin.org/"]
      iex> {:ok, circuit} = Breaker.start_link(options)
      iex> is_pid(circuit)
      true

  """
  @spec start_link([url: String.t], atom | tuple) :: GenServer.on_start()
  def start_link(options, name \\ nil) do
    GenServer.start_link(__MODULE__, options, name: name)
  end

  @doc """
  Checks if the given response is either a `%Breaker.OpenCircuitError{}`, a
  timeout, or has a status code >= 400.

  ## Parameters: ##

  * `response`: The response recieved from one of the HTTP method calls.

  ## Examples: ##

      iex> Breaker.error?(%Breaker.OpenCircuitError{})
      true

      iex> Breaker.error?(%HTTPoison.Error{})
      true

      iex> Breaker.error?(%HTTPoison.Response{status_code: 500})
      true

      iex> Breaker.error?(%HTTPoison.Response{status_code: 200})
      false

  """
  @spec error?(%Breaker.OpenCircuitError{} | %HTTPoison.Error{} |
  %HTTPoison.Response{}) :: boolean
  def error?(%Breaker.OpenCircuitError{}), do: true
  def error?(%HTTPoison.Error{}), do: true
  def error?(%{status_code: status_code}) when status_code >= 400, do: true
  def error?(_), do: false

  @doc """
  Trip the circuit.

  This sets the "open" status to true and has no effect if the "open" status
  is already true.

  This has the effect of cutting off communications using the circuit and
  starts the restoration process to test if the external source is healthy.

  ## Parameters ##

  * `circuit`: The pid of the breaker to trip.

  ## Examples: ##

      iex> {:ok, circuit} = Breaker.start_link([url: "http://httpbin.org/"])
      iex> response = Breaker.get(circuit, "/get") |> Task.await
      iex> response.status_code
      200
      iex> Breaker.trip(circuit)
      iex> Breaker.get(circuit, "/get") |> Task.await
      %Breaker.OpenCircuitError{message: "circuit is open"}

  """
  @spec trip(pid) :: :ok
  def trip(circuit), do: GenServer.call(circuit, :trip)

  @doc """
  Reset the circuit breaker.

  This sets the "open" status to false and has no effect if the "open" status
  is already false.

  This has the effect of restoring communications using the circuit, but it
  does not clear any recent unhealthy requests. As such, it could recalculate
  and trip itself again at the end of the next request or after a roll.

  ## Parameters: ##

  * `circuit`: The pid of the breaker to reset.

  ## Examples: ##

      iex> options = [url: "http://httpbin.org/", open: true]
      iex> {:ok, circuit} = Breaker.start_link(options)
      iex> Breaker.open?(circuit)
      true
      iex> Breaker.reset(circuit)
      iex> Breaker.open?(circuit)
      false

  """
  @spec reset(pid) :: :ok
  def reset(circuit), do: GenServer.call(circuit, :reset)

  @doc """
  Ask if the circuit is open or not.

  Don't forget, an open circuit is one that is not properly connected and thus
  does not allow electrons to flow. In this case, it does not allow
  communication to the external resource. I get this mixed up in my head
  sometimes.

  ## Parameters: ##

  * `circuit`: The pid of the breaker to check.

  ## Examples: ##

      iex> options = [url: "http://httpbin.org/"]
      iex> {:ok, circuit} = Breaker.start_link(options)
      iex> Breaker.open?(circuit)
      false

  """
  @spec open?(pid) :: boolean
  def open?(circuit), do: GenServer.call(circuit, :open?)

  @doc """
  Roll the window, creating a new bucket and possibly pushing out an old one,
  updating the sum values as necessary.

  ## Parameters: ##

  * `circuit`: The pid of the breaker to roll.

  ## Examples: ##

      iex> options = [url: "http://httpbin.org/", window: [%{total: 1, errors: 0}]]
      iex> {:ok, circuit} = Breaker.start_link(options)
      iex> Breaker.roll(circuit)
      :ok

  """
  @spec roll(pid) :: :ok
  def roll(circuit), do: GenServer.cast(circuit, :roll)

  @doc """
  Count a given response in the breaker's current bucket and sums.

  Adds the response to the current bucket of the health window, the total sum,
  and finalizes by recalculating the breaker's status.

  **You probably won't need to use this manually.**

  This is done automatically when a request is made through this module.

  ## Parameters: ##

  * `circuit`: The pid of the breaker to count in.
  * `response`: The response received from a request.

  ## Examples: ##

      iex> {:ok, circuit} = Breaker.start_link([url: "http://httpbin.org/"])
      iex> Breaker.count(circuit, %HTTPoison.Error{})
      :ok

  """
  @spec count(pid, %HTTPoison.Response{} | %HTTPoison.Error{}) :: :ok
  def count(circuit, response), do: GenServer.cast(circuit, {:count, response})

  #####
  # Request calls

  @doc """
  Make an async GET request to the specified path using the given breaker.

  Task returning alias for `make_request(circuit, path, :get, options)`.

  ## Parameters: ##

  * `circuit`: The breaker to perform the request.
  * `path`: The path string to append to the end of the breaker's `url`.
  * `options`: Additional options passed to HTTPoison.

  ## Examples: ##

      iex> {:ok, breaker} = Breaker.start_link([url: "http://httpbin.org/"])
      iex> request = Breaker.get(breaker, "/get")
      iex> response = Task.await(request)
      iex> response.status_code
      200

  """
  @spec get(pid, String.t, []) :: Task.t
  def get(circuit, path, options \\ []) do
    Task.async(__MODULE__, :make_request, [circuit, path, :get, options])
  end

  @doc """
  Make an async PUT request to the specified path using the given breaker.

  Task returning alias for `make_request(circuit, path, :put, options)`.

  ## Parameters: ##

  * `circuit`: The breaker to perform the request.
  * `path`: The path string to append to the end of the breaker's `url`.
  * `options`: Additional options passed to HTTPoison.

  """
  @spec put(pid, String.t, []) :: Task.t
  def put(circuit, path, options \\ []) do
    Task.async(__MODULE__, :make_request, [circuit, path, :put, options])
  end

  @doc """
  Make an async HEAD request to the specified path using the given breaker.

  Task returning alias for `make_request(circuit, path, :head, options)`.

  ## Parameters: ##

  * `circuit`: The breaker to perform the request.
  * `path`: The path string to append to the end of the breaker's `url`.
  * `options`: Additional options passed to HTTPoison.

  """
  @spec head(pid, String.t, []) :: Task.t
  def head(circuit, path, options \\ []) do
    Task.async(__MODULE__, :make_request, [circuit, path, :head, options])
  end

  @doc """
  Make an async POST request to the specified path using the given breaker.

  Task returning alias for `make_request(circuit, path, :post, options)`.

  ## Parameters: ##

  * `circuit`: The breaker to perform the request.
  * `path`: The path string to append to the end of the breaker's `url`.
  * `options`: Additional options passed to HTTPoison.

  """
  @spec post(pid, String.t, []) :: Task.t
  def post(circuit, path, options \\ []) do
    Task.async(__MODULE__, :make_request, [circuit, path, :post, options])
  end

  @doc """
  Make an async PATCH request to the specified path using the given breaker.

  Task returning alias for `make_request(circuit, path, :patch, options)`.

  ## Parameters: ##

  * `circuit`: The breaker to perform the request.
  * `path`: The path string to append to the end of the breaker's `url`.
  * `options`: Additional options passed to HTTPoison.

  """
  @spec patch(pid, String.t, []) :: Task.t
  def patch(circuit, path, options \\ []) do
    Task.async(__MODULE__, :make_request, [circuit, path, :patch, options])
  end

  @doc """
  Make an async DELETE request to the specified path using the given breaker.

  Task returning alias for `make_request(circuit, path, :delete, options)`.

  ## Parameters: ##

  * `circuit`: The breaker to perform the request.
  * `path`: The path string to append to the end of the breaker's `url`.
  * `options`: Additional options passed to HTTPoison.

  """
  @spec delete(pid, String.t, []) :: Task.t
  def delete(circuit, path, options \\ []) do
    Task.async(__MODULE__, :make_request, [circuit, path, :delete, options])
  end

  @doc """
  Make an async OPTIONS request to the specified path using the given breaker.

  Task returning alias for `make_request(circuit, path, :options, options)`.

  ## Parameters: ##

  * `circuit`: The breaker to perform the request.
  * `path`: The path string to append to the end of the breaker's `url`.
  * `options`: Additional options passed to HTTPoison.

  """
  @spec options(pid, String.t, []) :: Task.t
  def options(circuit, path, options \\ []) do
    Task.async(__MODULE__, :make_request, [circuit, path, :options, options])
  end

  @doc """
  Make an HTTP(S) request using the specified breaker, using the given method.

  This function isn't probably one you would want to use on your own and
  instead, use the method-specific functions (`Breaker.get()`). They return
  Tasks and are async, while this is sync.

  ## Parameters: ##

  * `circuit`: The circuit to make the request with.
  * `path`: The request path, this is add to the circuit's `url`.
  * `method`: An atom specifying the HTTP method, used by HTTPoison.
  * `options`: Extra options to pass to HTTPoison. The circuit's `timeout` and
    `headers` are also added to this.

  ## Examples: ##

      iex> {:ok, breaker} = Breaker.start_link([url: "http://httpbin.org/"])
      iex> response = Breaker.make_request(breaker, "/get", :get)
      iex> response.status_code
      200

  """
  @spec make_request(pid, String.t, atom, []) :: %HTTPoison.Response{} |
  %HTTPoison.Error{} | %Breaker.OpenCircuitError{}
  def make_request(circuit, path, method, options \\ []) do
    case GenServer.call(circuit, :options) do
      %Breaker.OpenCircuitError{} ->
        %Breaker.OpenCircuitError{}
      {headers, timeout, url} ->
        headers = options
        |> Keyword.get(:headers, [])
        |> Keyword.merge(headers, fn(_key, v1, _v2) -> v1 end)

        request_address = URI.merge(url, path)
        timeout = Keyword.get(options, :timeout, timeout)

        {_, response} =
          %HTTPoison.Request{
            method: method,
            url: request_address,
            body: Keyword.get(options, :body, []),
            headers: headers,
            options: [recv_timeout: timeout]
          }
          |> HTTPoison.request()

        Breaker.count(circuit, response)
        response
    end
  end

  ### GenServer API

  @spec init(keyword) :: {:ok | :stop, :missing_url | map}
  def init(options) do
    if Keyword.has_key?(options, :url) do
      state = options
      |> Enum.into(%{})
      |> Map.put_new(:headers, [])
      |> Map.put_new(:timeout, 3000)
      |> Map.put_new(:open, false)
      |> Map.put_new(:error_threshold, 0.05)
      |> Map.put_new(:window_length, 10)
      |> Map.put_new(:bucket_length, 1000)
      |> Map.put_new(:window, [%{total: 0, errors: 0}])
      |> Map.put_new(:sum, %{total: 0, errors: 0})
      :timer.apply_interval(state.bucket_length, __MODULE__, :roll, [self()])
      {:ok, state}
    else
      {:stop, :missing_url}
    end
  end

  @spec handle_call(atom | tuple, pid, Breaker.t) :: {atom, any, Breaker.t}
  def handle_call(:open?, _from, state) do
    {:reply, state.open, state}
  end
  def handle_call(:options, _from, state) do
    if state.open do
      {:reply, %Breaker.OpenCircuitError{}, state}
    else
      {:reply, {state.headers, state.timeout, state.url}, state}
    end
  end
  def handle_call(:trip, _from, state) do
    {:reply, :ok, Map.put(state, :open, true)}
  end
  def handle_call(:reset, _from, state) do
    {:reply, :ok, Map.put(state, :open, false)}
  end

  @spec handle_cast(atom | tuple, Breaker.t) :: {atom, Breaker.t}
  def handle_cast({:count, response}, state) do
    if Breaker.error?(response) do
      state = state
      |> count_miss()
      |> calculate_status()
      {:noreply, state}
    else
      state = state
      |> count_hit()
      |> calculate_status()
      {:noreply, state}
    end
  end
  def handle_cast(:recalculate, state) do
    {:noreply, calculate_status(state)}
  end
  def handle_cast(:roll, state) do
    state = state
    |> shift_window()
    |> trim_window()
    |> calculate_status()
    {:noreply, state}
  end

  ### Private API

  defp count_hit(state) do
    state
    |> add_to_current_window(:total)
    |> add_to_sum(:total)
  end

  defp count_miss(state) do
    state
    |> add_to_current_window(:error)
    |> add_to_sum(:error)
  end

  defp add_to_current_window(state, :total) do
    Map.update!(state, :window, fn([current | rest]) ->
      [Map.update!(current, :total, &(&1 + 1)) | rest]
    end)
  end
  defp add_to_current_window(state, :error) do
    Map.update!(state, :window, fn([current | rest]) ->
      current = current
      |> Map.update!(:total, &(&1 + 1))
      |> Map.update!(:errors, &(&1 + 1))
      [current | rest]
    end)
  end

  defp add_to_sum(state, :total) do
    Map.update!(state, :sum, fn(sum) ->
      Map.update!(sum, :total, &(&1 + 1))
    end)
  end
  defp add_to_sum(state, :error) do
    Map.update!(state, :sum, fn(sum) ->
      sum
      |> Map.update!(:total, &(&1 + 1))
      |> Map.update!(:errors, &(&1 + 1))
    end)
  end

  defp calculate_status(state) do
    if state.sum.total == 0 do
      Map.put(state, :open, false)
    else
      error_rate = state.sum.errors / state.sum.total
      Map.put(state, :open, error_rate > state.error_threshold)
    end
  end

  defp shift_window(state) do
    Map.update!(state, :window, &([%{total: 0, errors: 0} | &1]))
  end

  defp trim_window(state) do
    if length(state.window) <= state.window_length do
      state
    else
      {removed, window} = pop(state.window)
      state
      |> Map.put(:window, window)
      |> Map.update!(:sum, fn(sum) ->
        sum
        |> Map.update!(:total, &(&1 - removed.total))
        |> Map.update!(:errors, &(&1 - removed.errors))
      end)
    end
  end

  defp pop(list) do
    {List.last(list), List.delete_at(list, -1)}
  end
end
