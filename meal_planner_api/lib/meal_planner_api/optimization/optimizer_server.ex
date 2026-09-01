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
  - Spawns Python process on startup (via the injectable `OptimizerPortRunner`)
  - Reassembles frames across `:data` chunks into newline-terminated JSON
  - Implements circuit breaker (3 failures → open → after reset window → closed + restart)
  - Maps requests to responses via UUID matching
  - Cancels per-request timers on reply, replies `:optimizer_unavailable` on expiry
  - Falls back to `OptimizerFallback` when the circuit is open
  """

  use GenServer

  require Logger

  alias MealPlannerApi.Optimization.OptimizerFallback
  alias MealPlannerApi.Optimization.OptimizerPortRunner

  @behaviour MealPlannerApi.Optimization.OptimizerPort

  @circuit_failure_threshold 3
  @default_circuit_reset_timeout_ms 30_000
  @default_handshake_attempts 3
  @default_handshake_timeout_ms 3_000
  @default_frame_max_bytes 4 * 1024 * 1024

  @enforce_keys []
  defstruct port: nil,
            port_runner: OptimizerPortRunner,
            circuit_state: :closed,
            consecutive_failures: 0,
            last_failure_at: nil,
            pending_requests: %{},
            buffer: "",
            handshake_phase: :idle,
            handshake_attempts: 0

  # ============================================================================
  # Public API
  # ============================================================================

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def select_weekly_menu(payload) do
    GenServer.call(__MODULE__, {:solve, payload}, optimizer_timeout_ms())
  catch
    :exit, :timeout -> {:error, :optimizer_timeout}
    :exit, {:timeout, _} -> {:error, :optimizer_timeout}
    :exit, _reason -> {:error, :optimizer_unavailable}
  end

  @spec health_check() :: :ok | {:error, :optimizer_unavailable}
  @impl true
  def health_check, do: GenServer.call(__MODULE__, :health_check)

  # ============================================================================
  # GenServer callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    state = %__MODULE__{
      port_runner: Keyword.get(opts, :port_runner, port_runner())
    }

    case spawn_python(state) do
      {:ok, new_state} ->
        Process.send_after(self(), :handshake_timeout, handshake_timeout_ms())
        {:ok, %{new_state | handshake_phase: :pending, handshake_attempts: 1}}

      {:error, reason} ->
        Logger.warning("OptimizerServer failed to spawn Python: #{inspect(reason)}")
        {:stop, {:shutdown, reason}}
    end
  end

  @impl true
  def handle_call(:health_check, _from, state) do
    reply =
      case state do
        %{circuit_state: :open} -> {:error, :optimizer_unavailable}
        %{port: nil} -> {:error, :optimizer_unavailable}
        _ -> :ok
      end

    {:reply, reply, state}
  end

  def handle_call({:solve, payload}, from, %{circuit_state: :open} = state) do
    case maybe_reset_circuit(state) do
      {:ok, %{} = fresh} when fresh.circuit_state != :open ->
        dispatch_solve(payload, from, fresh)

      _ ->
        {:reply, OptimizerFallback.select_weekly_menu(payload), state}
    end
  end

  def handle_call({:solve, payload}, from, state) do
    dispatch_solve(payload, from, state)
  end

  @impl true
  def handle_info({port, {:data, raw}}, %{port: port} = state) do
    new_state = handle_data_chunk(raw, state)
    {:noreply, new_state, :hibernate}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) when status != 0 do
    Logger.warning("Python process exited with status #{status}")

    new_state =
      %{state | port: nil, buffer: "", handshake_phase: :idle}
      |> close_port()
      |> reply_unavailable_to_all_pending()
      |> record_failure()

    case new_state.circuit_state do
      :closed ->
        if new_state.consecutive_failures >= @circuit_failure_threshold do
          {:noreply, %{new_state | circuit_state: :open, last_failure_at: monotonic_ms()}}
        else
          {:noreply, schedule_restart(new_state)}
        end

      :open ->
        case maybe_reset_circuit(new_state) do
          {:ok, reset_state} -> {:noreply, reset_state}
          {:error, _} -> {:noreply, new_state}
        end
    end
  end

  def handle_info({port, {:exit_status, 0}}, %{port: port} = state) do
    Logger.info("Python process exited cleanly")
    new_state = reply_unavailable_to_all_pending(%{state | port: nil, buffer: ""})
    {:noreply, schedule_restart(new_state)}
  end

  def handle_info(:handshake_timeout, %{handshake_phase: :pending} = state) do
    if state.handshake_attempts >= handshake_attempts() do
      Logger.warning(
        "OptimizerServer handshake failed after #{state.handshake_attempts} attempts; shutting down"
      )

      state =
        state
        |> close_port()
        |> reply_unavailable_to_all_pending()
        |> Map.put(:handshake_phase, :idle)

      {:stop, {:shutdown, :handshake_timeout}, state}
    else
      Logger.warning(
        "OptimizerServer handshake attempt #{state.handshake_attempts + 1}/#{handshake_attempts()} timed out; retrying"
      )

      if state.port, do: send_handshake(state.port)

      Process.send_after(self(), :handshake_timeout, handshake_timeout_ms())

      {:noreply, %{state | handshake_attempts: state.handshake_attempts + 1}}
    end
  end

  def handle_info(:handshake_timeout, state), do: {:noreply, state}

  def handle_info({:request_timeout, request_id}, state) do
    case Map.get(state.pending_requests, request_id) do
      nil ->
        {:noreply, state}

      %{from: from, timer_ref: timer_ref} ->
        :ok = GenServer.reply(from, {:error, :optimizer_unavailable})
        cancel_timer(timer_ref)
        Logger.warning("OptimizerServer request #{request_id} timed out")

        new_state =
          %{state | pending_requests: Map.delete(state.pending_requests, request_id)}
          |> record_failure()
          |> maybe_open_circuit()

        {:noreply, new_state, :hibernate}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state, :hibernate}

  @impl true
  def terminate(_reason, state) do
    _ =
      state
      |> reply_unavailable_to_all_pending()
      |> close_port()

    :ok
  end

  # ============================================================================
  # Private helpers
  # ============================================================================

  defp port_runner do
    Application.get_env(:meal_planner_api, :optimizer_port_runner, OptimizerPortRunner)
  end

  defp optimizer_timeout_ms do
    Application.get_env(:meal_planner_api, :optimizer_timeout_ms, 15_000)
  end

  # Per-request timer — defaults to the call timeout but can be overridden in
  # tests so the call timeout fires independently of the server-side timer.
  defp optimizer_request_timeout_ms do
    Application.get_env(
      :meal_planner_api,
      :optimizer_request_timeout_ms,
      optimizer_timeout_ms()
    )
  end

  defp handshake_timeout_ms do
    Application.get_env(
      :meal_planner_api,
      :optimizer_handshake_timeout_ms,
      @default_handshake_timeout_ms
    )
  end

  defp handshake_attempts do
    Application.get_env(
      :meal_planner_api,
      :optimizer_handshake_attempts,
      @default_handshake_attempts
    )
  end

  defp frame_max_bytes do
    Application.get_env(
      :meal_planner_api,
      :optimizer_frame_max_bytes,
      @default_frame_max_bytes
    )
  end

  defp circuit_reset_timeout_ms do
    Application.get_env(
      :meal_planner_api,
      :optimizer_circuit_reset_timeout_ms,
      @default_circuit_reset_timeout_ms
    )
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp dispatch_solve(payload, from, state) do
    case ensure_port(state) do
      {:ok, state} ->
        request_id = UUID.uuid4()
        timer_ref = schedule_request_timeout(request_id)
        send_solve_request(state.port, request_id, payload)

        entry = %{
          from: from,
          payload: payload,
          started_at: monotonic_ms(),
          timer_ref: timer_ref
        }

        new_state = put_in(state.pending_requests[request_id], entry)
        {:noreply, new_state}

      {:error, reason, state} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp schedule_request_timeout(request_id) do
    Process.send_after(
      self(),
      {:request_timeout, request_id},
      optimizer_request_timeout_ms()
    )
  end

  defp spawn_python(state) do
    case state.port_runner.open_port() do
      {:ok, port} ->
        send_handshake(port)
        {:ok, %{state | port: port}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp restart_python(state) do
    state =
      state
      |> close_port()
      |> reply_unavailable_to_all_pending()
      |> then(&%{&1 | buffer: "", handshake_phase: :idle})

    case spawn_python(state) do
      {:ok, new_state} ->
        Process.send_after(self(), :handshake_timeout, handshake_timeout_ms())
        {:ok, %{new_state | handshake_phase: :pending, handshake_attempts: 1}}

      {:error, _} = err ->
        err
    end
  end

  defp ensure_port(state) do
    cond do
      state.port == nil ->
        try_restart(state)

      handshake_ready?(state) ->
        {:ok, state}

      true ->
        {:error, :optimizer_unavailable, state}
    end
  end

  defp try_restart(state) do
    case restart_python(state) do
      {:ok, new_state} ->
        # restart_python always lands in :pending until the next ready frame,
        # so we cannot serve traffic synchronously from a fresh restart.
        {:error, :optimizer_unavailable, new_state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp handshake_ready?(%{handshake_phase: :ready, port: port}) when not is_nil(port) do
    case Port.info(port, :name) do
      {:name, name} when is_list(name) and name != [] -> true
      _ -> false
    end
  end

  defp handshake_ready?(_), do: false

  defp schedule_restart(state) do
    case restart_python(state) do
      {:ok, new_state} ->
        new_state

      {:error, reason} ->
        Logger.warning("OptimizerServer restart_python failed: #{inspect(reason)}")

        state
        |> record_failure()
        |> maybe_open_circuit()
    end
  end

  defp close_port(%{port: nil} = state), do: state

  defp close_port(%{port: port} = state) do
    if is_port(port) do
      try do
        Port.close(port)
      catch
        _kind, _value -> :ok
      end
    end

    %{state | port: nil}
  end

  defp send_handshake(port) do
    Port.command(port, ~s({"type":"handshake","version":"1.0"}\n))
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

  # --------------------------------------------------------------------------
  # Frame reassembly
  # --------------------------------------------------------------------------

  defp handle_data_chunk(raw, state) do
    combined = state.buffer <> raw
    cap = frame_max_bytes()

    cond do
      not String.contains?(combined, "\n") and byte_size(combined) > cap ->
        overflow_reply(state)

      true ->
        {frames, rest} = split_newlines(combined)
        state = %{state | buffer: rest}

        Enum.reduce(frames, state, &dispatch_frame/2)
    end
  end

  defp split_newlines(binary) do
    case :binary.split(binary, "\n") do
      [only] -> {[], only}
      list -> {Enum.drop(list, -1), List.last(list)}
    end
  end

  defp dispatch_frame("", state), do: state

  defp dispatch_frame(frame, state) do
    case Jason.decode(frame) do
      {:ok, decoded} ->
        route_frame(decoded, state)

      {:error, reason} ->
        Logger.warning(
          "OptimizerServer dropping malformed frame (#{byte_size(frame)} bytes): #{inspect(reason)}"
        )

        state
    end
  end

  defp route_frame(%{"type" => "ready"}, %{handshake_phase: :pending} = state) do
    %{state | handshake_phase: :ready, handshake_attempts: 0, buffer: ""}
  end

  defp route_frame(%{"type" => "ready"}, state) do
    # Late ready — already in :ready or never received a handshake. Ignore.
    state
  end

  defp route_frame(%{"type" => "solution", "id" => request_id, "result" => result}, state) do
    handle_solution(request_id, result, state)
  end

  defp route_frame(%{"type" => "error", "id" => request_id, "error" => reason}, state) do
    handle_error_frame(request_id, reason, state)
  end

  defp route_frame(%{"type" => _}, %{handshake_phase: :pending} = state) do
    Logger.warning("OptimizerServer received non-handshake frame during handshake; dropping")
    state
  end

  defp route_frame(other, state) do
    Logger.warning("OptimizerServer received unknown frame type: #{inspect(other)}")
    state
  end

  defp handle_solution(request_id, result, state) do
    case Map.pop(state.pending_requests, request_id) do
      {nil, _pending} ->
        Logger.warning("OptimizerServer solution for unknown id #{request_id}")
        state

      {%{from: from, timer_ref: timer_ref}, new_pending} ->
        cancel_timer(timer_ref)
        :ok = reply_to(from, {:ok, result})

        %{
          state
          | pending_requests: new_pending,
            consecutive_failures: 0,
            circuit_state: :closed
        }
    end
  end

  defp handle_error_frame(request_id, reason, state) do
    Logger.warning("OptimizerServer error for #{request_id}: #{reason}")

    case Map.pop(state.pending_requests, request_id) do
      {nil, _pending} ->
        state

      {%{from: from, timer_ref: timer_ref}, new_pending} ->
        cancel_timer(timer_ref)
        reply_to(from, {:error, :optimizer_error})

        new_state = %{state | pending_requests: new_pending}
        new_state = %{new_state | consecutive_failures: new_state.consecutive_failures + 1}
        maybe_open_circuit(new_state)
    end
  end

  defp overflow_reply(state) do
    Logger.warning("OptimizerServer dropping oversize frame; affected request unavailable")

    # FIFO assumption: oldest pending request is the one we were expecting a response for.
    case Enum.find(state.pending_requests, fn _ -> true end) do
      {request_id, %{from: from, timer_ref: timer_ref}} ->
        reply_to(from, {:error, :frame_too_large})
        cancel_timer(timer_ref)
        %{state | pending_requests: Map.delete(state.pending_requests, request_id), buffer: ""}

      nil ->
        %{state | buffer: ""}
    end
  end

  defp reply_to(nil, _reply), do: :ok

  defp reply_to(from, reply), do: GenServer.reply(from, reply)

  defp cancel_timer(nil), do: :ok

  defp cancel_timer(ref) do
    _ = Process.cancel_timer(ref, async: true, info: false)
    :ok
  end

  # --------------------------------------------------------------------------
  # Pending / circuit helpers
  # --------------------------------------------------------------------------

  defp reply_unavailable_to_all_pending(state) do
    Enum.each(state.pending_requests, fn {_id, %{from: from, timer_ref: timer_ref}} ->
      reply_to(from, {:error, :optimizer_unavailable})
      cancel_timer(timer_ref)
    end)

    %{state | pending_requests: %{}}
  end

  defp record_failure(state) do
    %{state | consecutive_failures: state.consecutive_failures + 1}
  end

  defp maybe_open_circuit(state) do
    if state.consecutive_failures >= @circuit_failure_threshold and state.circuit_state == :closed do
      Logger.warning(
        "OptimizerServer circuit breaker OPEN after #{state.consecutive_failures} failures"
      )

      %{state | circuit_state: :open, last_failure_at: monotonic_ms()}
    else
      state
    end
  end

  defp maybe_reset_circuit(%{circuit_state: :open, last_failure_at: ts} = state) do
    if ts != nil and monotonic_ms() - ts >= circuit_reset_timeout_ms() do
      Logger.warning("OptimizerServer circuit breaker reset; restarting Python")

      case restart_python(%{state | circuit_state: :closed, last_failure_at: nil}) do
        {:ok, new_state} -> {:ok, new_state}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, state}
    end
  end

  defp maybe_reset_circuit(state), do: {:ok, state}
end
