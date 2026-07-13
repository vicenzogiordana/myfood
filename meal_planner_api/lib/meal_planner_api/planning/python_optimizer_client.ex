defmodule MealPlannerApi.Planning.PythonOptimizerClient do
  @moduledoc """
  `OptimizerPort`-compliant delegate to `MealPlannerApi.Optimization.OptimizerServer`
  — the real, working Port-based GenServer that owns the `optimizador.py`
  process (handshake protocol, circuit breaker, timeouts).

  ## Why this indirection exists

  `config/config.exs` used to point `:planning_optimizer_client` (consumed
  by `PlanningService.client_module/0`, the legacy weekly-plan pipeline) at
  this exact module name — except the module didn't exist. Every real
  (non-test) call to `PlanningService.generate_weekly_plan/3` raised
  `UndefinedFunctionError`.

  Pointing the config directly at `OptimizerServer` instead isn't safe,
  because of two payload-shape mismatches between the two pipelines:

  1. `PlanningService.build_optimization_payload/3` (legacy) builds a
     STRING-keyed top-level map (`"days"`, `"slots"`, `"constraints"`,
     `"candidates_by_slot"`). `OptimizerServer`'s own circuit-breaker
     fallback, `OptimizerFallback.select_weekly_menu/1`, pattern-matches an
     ATOM-keyed payload (`%{days: _, candidates_by_slot: _} = payload`).
     Passing the legacy payload straight through would work while the real
     Python solver is healthy (`Jason.encode!/1` doesn't care about atom vs
     string Elixir keys — it's JSON on the wire either way) but would raise
     `MatchError` **inside** `OptimizerServer`'s own `handle_call/3`
     whenever its circuit breaker opens, crashing the shared, singleton
     `OptimizerServer` process for every caller — not just this one.
  2. On a successful real-solver round trip, `OptimizerServer` replies with
     the raw `Jason.decode/1` of the Python response — a STRING-keyed
     `%{"meals" => [...]}`. `PlanningService.generate_weekly_plan/3` reads
     `result.meals` (dot notation — requires an ATOM key `:meals`), which
     would raise `KeyError` on every real (non-fallback) response.

  This module normalizes both directions so the legacy pipeline can safely
  ride on the same real optimizer/circuit-breaker/fallback stack the newer
  `Generation.Server` pipeline uses, instead of talking to a module that
  doesn't exist.
  """

  @behaviour MealPlannerApi.Optimization.OptimizerPort

  alias MealPlannerApi.Optimization.OptimizerServer

  @impl true
  def select_weekly_menu(payload) do
    payload
    |> to_optimizer_port_payload()
    |> OptimizerServer.select_weekly_menu()
    |> normalize_result()
  end

  @impl true
  def health_check, do: OptimizerServer.health_check()

  # -------------------------------------------------------------------------
  # Payload translation (public/@doc false so the test suite can assert on
  # the exact shape without needing the live Port/Python process — see
  # `Accounts.build_identity_multi/4` for the same visibility rationale).
  # -------------------------------------------------------------------------

  @doc false
  @spec to_optimizer_port_payload(map()) ::
          MealPlannerApi.Optimization.OptimizerPort.optimizer_payload()
  def to_optimizer_port_payload(payload) do
    %{
      days: fetch(payload, :days, "days"),
      slots: fetch(payload, :slots, "slots"),
      constraints: fetch(payload, :constraints, "constraints"),
      candidates_by_slot: fetch(payload, :candidates_by_slot, "candidates_by_slot")
    }
  end

  @doc false
  @spec normalize_result(MealPlannerApi.Optimization.OptimizerPort.optimizer_result()) ::
          {:ok, %{meals: [map()]}} | {:error, term()}
  def normalize_result({:ok, %{meals: meals}}), do: {:ok, %{meals: meals}}
  def normalize_result({:ok, %{"meals" => meals}}), do: {:ok, %{meals: meals}}
  def normalize_result({:error, _} = error), do: error

  defp fetch(payload, atom_key, string_key) do
    case Map.fetch(payload, atom_key) do
      {:ok, value} -> value
      :error -> Map.get(payload, string_key)
    end
  end
end
