defmodule MealPlannerApi.PlanningAgent.Optimizer.Port do
  @moduledoc """
  Runs the existing Python OR-Tools optimizer for one `run_optimizer` call
  through `MealPlannerApi.Optimization.OptimizerPortRunner` (spec #93,
  "reuse the Python OR-Tools optimizer and the port runner; do not reuse the
  named singleton optimizer server").

  Each call owns its subprocess: handshake, one solve request, then the port
  is closed. On timeout, or when the calling process dies first (for example
  a `:brutal_kill` cancel), the OS process is force-killed. Every failure is a
  typed error and there is no greedy fallback:

    * `:optimizer_unavailable` — the subprocess could not start or never
      became ready
    * `:optimizer_timeout` — no answer within the deadline (inconclusive)
    * `:optimizer_crashed` — the subprocess exited before answering, or
      was already gone when a request was written
    * `:optimizer_busy` — the global cap on concurrent optimizer
      subprocesses of every Planning Session was full, so no subprocess
      started (issue #118)
    * `:optimizer_unconfigured` — the concurrency cap is not configured; it
      is a human decision, so no subprocess ever starts without it
    * the optimizer's own error reason (for example `:infeasible`) with its
      details

  ## Options

    * `:timeout_ms` — overall deadline (default 120 s)
    * `:port_runner` — module with `open_port/1` (default from
      `:optimizer_port_runner` config, else `OptimizerPortRunner`)
    * `:python_executable`, `:script_path` — forwarded to the port runner
    * `:max_concurrent_runs` — global cap on optimizer subprocesses running
      at once (default from `config :meal_planner_api,
      MealPlannerApi.PlanningAgent.Optimizer.Port`, unset by default)
    * `:concurrency_limiter` — the `MealPlannerApi.PlanningAgent.ConcurrencyLimiter`
      holding the slots (default: the planning agent's)
    * `:on_os_process` — 1-arity function told `{:started, os_pid}` as soon
      as the subprocess exists and `{:closed, os_pid}` once this call no
      longer owns it, so an owner (the Planning Session) can force-kill a
      busy solver synchronously on Stop or Cancel
  """

  @behaviour MealPlannerApi.PlanningAgent.Optimizer

  require Logger

  alias MealPlannerApi.Optimization.OptimizerPortRunner
  alias MealPlannerApi.PlanningAgent.{ConcurrencyLimiter, OsProcess}

  @default_timeout_ms 120_000
  # Every error code optimizador.py returns; the Port test reads the
  # validation codes from optimizador.py so a new one cannot be missed.
  @known_errors ~w(infeasible unbounded abnormal solver_unavailable invalid_days invalid_slots
                   invalid_constraints invalid_candidates invalid_budget invalid_macro_bounds
                   invalid_excluded_recipes invalid_variety_cap invalid_prior_meals
                   invalid_time_limit invalid_fixed_meals invalid_avoided_meals
                   invalid_skipped_meals inconclusive missing_slot_candidates invalid_candidate missing_payload)
                |> Map.new(&{&1, String.to_atom(&1)})

  @impl true
  def solve(payload, opts \\ []) do
    limiter = Keyword.get(opts, :concurrency_limiter, ConcurrencyLimiter)

    cap =
      Keyword.get_lazy(opts, :max_concurrent_runs, fn ->
        :meal_planner_api
        |> Application.get_env(__MODULE__, [])
        |> Keyword.get(:max_concurrent_runs)
      end)

    # The slot is held by the calling process, so a caller killed mid-solve
    # frees it as well.
    case ConcurrencyLimiter.run(limiter, :optimizer_runs, cap, fn ->
           run_subprocess(payload, opts)
         end) do
      {:ok, result} -> result
      {:error, :at_capacity} -> {:error, :optimizer_busy, %{}}
      {:error, :unconfigured} -> {:error, :optimizer_unconfigured, %{}}
    end
  end

  defp run_subprocess(payload, opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    case open(opts) do
      {:ok, port} ->
        os_pid = os_pid(port)
        notify = Keyword.get(opts, :on_os_process, fn _event -> :ok end)
        reaper = start_reaper(os_pid)
        if os_pid, do: notify.({:started, os_pid})

        try do
          run(port, payload, deadline)
        after
          close(port)
          send(reaper, :done)
          if os_pid, do: notify.({:closed, os_pid})
        end

      :error ->
        {:error, :optimizer_unavailable, %{}}
    end
  end

  defp run(port, payload, deadline) do
    request_id = Ecto.UUID.generate()
    Port.command(port, ~s({"type":"handshake","version":"1.0"}\n))

    with {:ok, %{"type" => "ready"}, buffer} <- await(port, "", deadline, &ready?/1) do
      Port.command(
        port,
        Jason.encode!(%{"type" => "solve", "id" => request_id, "payload" => payload}) <> "\n"
      )

      case await(port, buffer, deadline, &answer?(&1, request_id)) do
        {:ok, %{"type" => "solution", "result" => result}, _buffer} ->
          {:ok, result}

        {:ok, %{"type" => "error", "error" => reason} = frame, _buffer} ->
          {:error, error_reason(reason), Map.get(frame, "details") || %{}}

        {:error, reason, details} ->
          {:error, reason, details}
      end
    else
      {:error, :optimizer_timeout, _} -> {:error, :optimizer_unavailable, %{}}
      {:error, reason, details} -> {:error, reason, details}
    end
  rescue
    # Writing to a subprocess that already exited raises `badarg`.
    ArgumentError -> {:error, :optimizer_crashed, %{}}
  end

  defp ready?(frame), do: frame["type"] == "ready"

  defp answer?(frame, request_id),
    do: frame["type"] in ["solution", "error"] and frame["id"] == request_id

  # Reads newline-terminated JSON frames until one matches, skipping any
  # non-protocol output line.
  defp await(port, buffer, deadline, match?) do
    case next_frame(buffer, match?) do
      {:ok, frame, rest} ->
        {:ok, frame, rest}

      {:more, rest} ->
        remaining = deadline - System.monotonic_time(:millisecond)

        receive do
          {^port, {:data, data}} ->
            await(port, rest <> data, deadline, match?)

          {^port, {:exit_status, status}} ->
            {:error, :optimizer_crashed, %{"exit_status" => status}}
        after
          max(remaining, 0) ->
            kill(port)
            {:error, :optimizer_timeout, %{}}
        end
    end
  end

  defp next_frame(buffer, match?) do
    case :binary.split(buffer, "\n") do
      [incomplete] ->
        {:more, incomplete}

      [line, rest] ->
        case Jason.decode(line) do
          {:ok, %{} = frame} ->
            if match?.(frame), do: {:ok, frame, rest}, else: next_frame(rest, match?)

          _ ->
            next_frame(rest, match?)
        end
    end
  end

  defp open(opts) do
    runner =
      Keyword.get_lazy(opts, :port_runner, fn ->
        Application.get_env(:meal_planner_api, :optimizer_port_runner, OptimizerPortRunner)
      end)

    case runner.open_port(Keyword.take(opts, [:python_executable, :script_path])) do
      {:ok, port} -> {:ok, port}
      _ -> :error
    end
  rescue
    error ->
      Logger.warning("planning agent optimizer failed to start: #{Exception.message(error)}")
      :error
  end

  # A caller killed with `:brutal_kill` skips the `after` block, and closing
  # the port only closes stdin, which a busy solver does not read. The reaper
  # monitors the caller and force-kills the OS process if the caller dies
  # before the call finishes.
  defp start_reaper(os_pid) do
    owner = self()

    spawn(fn ->
      ref = Process.monitor(owner)

      receive do
        :done -> :ok
        {:DOWN, ^ref, :process, _, _} -> OsProcess.kill(os_pid)
      end
    end)
  end

  defp kill(port), do: port |> os_pid() |> OsProcess.kill()

  defp os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> os_pid
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp close(port) do
    Port.close(port)
  rescue
    _ -> :ok
  end

  defp error_reason(reason), do: Map.get(@known_errors, reason, :optimizer_error)
end
