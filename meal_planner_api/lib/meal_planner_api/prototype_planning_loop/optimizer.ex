# Throwaway prototype for issue #88 (bounded planning loop). Not production code.
defmodule MealPlannerApi.PrototypePlanningLoop.Optimizer do
  @moduledoc """
  Calls the real OR-Tools solver (`optimizador.py`) over its JSON-lines
  protocol. The port is opened through the backend's own
  `OptimizerPortRunner`, which needs neither the Repo nor the application
  supervision tree. `OptimizerServer` is not reused: it is a named singleton
  that silently switches to a non-solver fallback when its circuit opens,
  which would hide exactly what this prototype wants to observe.

  One short-lived Python process per solve: slow, simple, good enough here.
  """

  alias MealPlannerApi.Optimization.OptimizerPortRunner

  @timeout_ms 20_000

  @doc """
  Interpreter with `ortools`: `OPTIMIZER_PYTHON` when set (the backend's own
  override), otherwise the repository `.venv`, otherwise `python3` on PATH.
  """
  def python do
    venv = Path.expand("../../../../.venv/bin/python", __DIR__)

    cond do
      env = System.get_env("OPTIMIZER_PYTHON") -> System.find_executable(env) || env
      File.exists?(venv) -> venv
      true -> System.find_executable("python3") || "python3"
    end
  end

  @doc """
  Returns `{:ok, %{"meals" => [...]}}`, `{:error, %{"error" => ..., "causes" => [...]}}`
  for a solver-reported error, or `{:error, %{"error" => "optimizer_unavailable", ...}}`.
  """
  def solve(payload) do
    {:ok, port} = OptimizerPortRunner.open_port(python_executable: python())
    deadline = System.monotonic_time(:millisecond) + @timeout_ms

    try do
      send_json(port, %{type: "handshake", version: "1.0"})

      with {:ok, %{"type" => "ready"}, buffer} <- read_message(port, "", deadline),
           :ok <- send_json(port, %{type: "solve", id: "prototype-88", payload: payload}),
           {:ok, reply, _buffer} <- read_message(port, buffer, deadline) do
        case reply do
          %{"type" => "solution", "result" => result} ->
            {:ok, result}

          %{"type" => "error", "error" => error} ->
            {:error, %{"error" => error, "causes" => get_in(reply, ["details", "causes"]) || []}}
        end
      else
        {:error, reason} ->
          {:error,
           %{"error" => "optimizer_unavailable", "detail" => reason, "python" => python()}}
      end
    after
      if Port.info(port), do: Port.close(port)
    end
  end

  defp send_json(port, message) do
    Port.command(port, Jason.encode!(message) <> "\n")
    :ok
  end

  # Reads until one full line decodes as a protocol message. Non-JSON lines
  # (stderr is merged into stdout by the runner) are kept as failure detail.
  defp read_message(port, buffer, deadline, noise \\ "") do
    case String.split(buffer, "\n", parts: 2) do
      [line, rest] ->
        case Jason.decode(line) do
          {:ok, %{"type" => _} = message} -> {:ok, message, rest}
          _ -> read_message(port, rest, deadline, noise <> line <> "\n")
        end

      [partial] ->
        remaining = max(deadline - System.monotonic_time(:millisecond), 0)

        receive do
          {^port, {:data, data}} ->
            read_message(port, partial <> data, deadline, noise)

          {^port, {:exit_status, status}} ->
            {:error, "exit #{status}: #{String.slice(noise <> partial, 0, 400)}"}
        after
          remaining -> {:error, "timeout after #{@timeout_ms} ms"}
        end
    end
  end
end
