defmodule MealPlannerApi.Optimization.OptimizerServer do
  @moduledoc """
  Persistent GenServer that owns the Python optimizer process via Port.

  Communication protocol (JSON over stdio):
  - Startup: Elixir sends `{"type":"handshake","version":"1.0"}`,
    Python responds `{"type":"ready","version":"1.0"}`
  - Request: Elixir sends `{"type":"solve","id":"<uuid>","payload":{...}}`
  - Response: Python responds `{"type":"solution","id":"<uuid>","result":{...}}`
    or `{"type":"error","id":"<uuid>","error":"..."}`

  Responsibilities:
  - Spawns Python process on startup
  - Implements circuit breaker (3 failures → open → 30s reset)
  - Maps requests to responses via UUID matching
  - Delegates to OptimizerFallback when circuit is open
  """

  use GenServer
  alias MealPlannerApi.Optimization.OptimizerFallback

  @behaviour MealPlannerApi.Optimization.OptimizerPort

  @default_timeout_ms 15_000
  @circuit_failure_threshold 3
  @circuit_reset_timeout_ms 30_000

  @enforce_keys []
  defstruct port: nil,
            python_pid: nil,
            circuit_state: :closed,
            consecutive_failures: 0,
            last_failure_at: nil,
            pending_requests: %{},
            next_request_id: 1

  # ============================================================================
  # Public API
  # ============================================================================

  @spec start_link(any()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def select_weekly_menu(payload) do
    GenServer.call(__MODULE__, {:solve, payload}, @default_timeout_ms)
  rescue
    _ -> {:error, :optimizer_timeout}
  end

  @spec health_check() :: :ok | {:error, :optimizer_unavailable}
  @impl true
  def health_check, do: GenServer.call(__MODULE__, :health_check)

  # ============================================================================
  # GenServer callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    state = %__MODULE__{}

    case spawn_python(state) do
      {:ok, new_state} ->
        {:ok, new_state, {:continue, :wait_handshake}}

      {:error, reason} ->
        {:stop, {:shutdown, reason}}
    end
  end

  @impl true
  def handle_continue(:wait_handshake, %{port: port} = state) when port != nil do
    receive do
      {^port, {:data, raw}} ->
        case Jason.decode(raw) do
          {:ok, %{"type" => "ready", "version" => _}} ->
            {:noreply, state}

          _ ->
            {:noreply, state, {:continue, :wait_handshake}}
        end
    after
      10_000 ->
        {:stop, {:shutdown, :handshake_timeout}, state}
    end
  end

  @impl true
  def handle_call(:health_check, _from, state) do
    reply =
      if state.circuit_state == :open do
        {:error, :optimizer_unavailable}
      else
        :ok
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_call({:solve, payload}, _from, %{circuit_state: :open} = state) do
    result = OptimizerFallback.select_weekly_menu(payload)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:solve, payload}, from, state) do
    request_id = "req-#{state.next_request_id}"

    :ok = send_solve_request(state.port, request_id, payload)

    new_pending =
      Map.put(state.pending_requests, request_id, %{
        from: from,
        payload: payload,
        started_at: DateTime.utc_now()
      })

    new_state = %{
      state
      | pending_requests: new_pending,
        next_request_id: state.next_request_id + 1
    }

    {:noreply, new_state, @default_timeout_ms}
  end

  @impl true
  def handle_info({port, {:data, raw}}, %{port: port} = state) do
    case Jason.decode(raw) do
      {:ok, %{"type" => "solution", "id" => request_id, "result" => result}} ->
        handle_solution(request_id, result, state)

      {:ok, %{"type" => "error", "id" => request_id, "error" => reason}} ->
        handle_error(request_id, reason, state)

      _ ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, %{port: port, python_pid: _pid} = state)
      when status != 0 do
    IO.puts("Python process exited with status #{status}")

    new_state = %{state | port: nil, consecutive_failures: state.consecutive_failures + 1}

    case state.circuit_state do
      :closed ->
        if new_state.consecutive_failures >= @circuit_failure_threshold do
          IO.puts("Circuit breaker OPEN - using fallback")
          {:noreply, %{new_state | circuit_state: :open, last_failure_at: DateTime.utc_now()}}
        else
          new_state2 = restart_python(new_state)
          {:noreply, new_state2}
        end

      :open ->
        elapsed = DateTime.diff(DateTime.utc_now(), state.last_failure_at, :millisecond)

        if elapsed >= @circuit_reset_timeout_ms do
          IO.puts("Circuit reset - attempting restart")

          new_state2 =
            restart_python(%{new_state | circuit_state: :half_open, last_failure_at: nil})

          {:noreply, new_state2}
        else
          {:noreply, new_state}
        end
    end
  end

  @impl true
  def handle_info(:timeout, state) do
    # Timeout waiting for response - treat as failure
    IO.puts("Optimizer request timed out")

    new_state = %{state | consecutive_failures: state.consecutive_failures + 1}

    if new_state.consecutive_failures >= @circuit_failure_threshold do
      IO.puts("Circuit breaker OPEN - using fallback")
      {:noreply, %{new_state | circuit_state: :open, last_failure_at: DateTime.utc_now()}}
    else
      {:noreply, new_state}
    end
  end

  # ============================================================================
  # Private helpers
  # ============================================================================

  defp spawn_python(state) do
    python_executable = Application.get_env(:meal_planner_api, :optimizer_python, "python3")

    script_path =
      Application.get_env(
        :meal_planner_api,
        :optimizer_script_path,
        Path.expand("../../../../optimizador.py", __DIR__)
      )

    python_port =
      Port.open({:spawn, "#{python_executable} \"#{script_path}\""}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout
      ])

    port_info = Port.info(python_port)

    pname = Keyword.get(port_info, :name)
    pname_ok = is_list(pname) and length(pname) > 0

    cond do
      pname_ok ->
        Port.command(python_port, ~s({"type":"handshake","version":"1.0"}\n))
        {:ok, %{state | port: python_port, python_pid: port_info}}

      true ->
        {:error, :spawn_failed}
    end
  end

  defp restart_python(state) do
    case spawn_python(%{state | port: nil, pending_requests: %{}}) do
      {:ok, new_state} -> {:ok, new_state}
      {:error, _} = err -> err
    end
  end

  defp send_solve_request(port, request_id, payload) do
    message =
      Jason.encode!(%{
        "type" => "solve",
        "id" => request_id,
        "payload" => payload
      })

    Port.command(port, message <> "\n")
  end

  defp handle_solution(request_id, result, state) do
    case Map.pop(state.pending_requests, request_id) do
      {nil, _pending} ->
        {:noreply, state}

      {%{from: from, payload: _payload}, new_pending} ->
        :ok = GenServer.reply(from, {:ok, result})

        new_state = %{
          state
          | pending_requests: new_pending,
            consecutive_failures: 0,
            circuit_state: :closed
        }

        {:noreply, new_state}
    end
  end

  defp handle_error(request_id, reason, state) do
    IO.puts("Optimizer error for #{request_id}: #{reason}")

    case Map.pop(state.pending_requests, request_id) do
      {nil, _pending} ->
        {:noreply, state}

      {%{from: from, payload: _payload}, new_pending} ->
        :ok = GenServer.reply(from, {:error, :optimizer_error})

        new_state = %{
          state
          | pending_requests: new_pending,
            consecutive_failures: state.consecutive_failures + 1
        }

        if new_state.consecutive_failures >= @circuit_failure_threshold do
          IO.puts("Circuit breaker OPEN")
          {:noreply, %{new_state | circuit_state: :open, last_failure_at: DateTime.utc_now()}}
        else
          {:noreply, new_state}
        end
    end
  end
end
