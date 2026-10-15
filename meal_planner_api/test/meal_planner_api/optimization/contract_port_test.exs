defmodule MealPlannerApi.Optimization.ContractPortTest do
  @moduledoc """
  Drives the real `optimizador.py` through `OptimizerPortRunner` and checks the
  reply against the Elixir contract. Runs only when `OPTIMIZER_PYTHON` points
  to an interpreter with the pinned OR-Tools (`requirements.txt`).
  """

  use ExUnit.Case, async: true

  alias MealPlannerApi.Optimization.{Contract, OptimizerPortRunner}
  alias MealPlannerApi.Planning.ProposalStatus

  @python System.get_env("OPTIMIZER_PYTHON")

  if is_nil(@python) do
    @moduletag skip: "set OPTIMIZER_PYTHON to an interpreter with OR-Tools installed"
  end

  @goal %{
    calories: %{min: 700, max: 900},
    protein_g: %{min: 0, max: 1_000},
    carbs_g: %{min: 0, max: 1_000},
    fat_g: %{min: 0, max: 1_000}
  }

  test "conflicting goals come back as the closest plan requiring approval" do
    payload = %{
      "days" => ["2026-09-07"],
      "slots" => ["lunch"],
      "constraints" => %{
        "weekly_budget_cents" => 500,
        "macro_bounds" => Contract.nutrition_bounds(@goal)
      },
      "candidates_by_slot" => %{
        "lunch" => [
          candidate("cheap", 100, 300),
          candidate("filling", 900, 800)
        ]
      }
    }

    assert {:ok, plan} = payload |> solve() |> Contract.interpret()

    assert plan.meals == [%{date: ~D[2026-09-07], slot: "lunch", recipe_id: "cheap"}]
    assert plan.optimality == :optimal

    assert [%{goal: :calories, direction: :below_min, bound: 700, actual: 300, amount: 400}] =
             plan.deviations

    assert ProposalStatus.classify([], plan.deviations) == :requires_approval
  end

  test "a Restriction that empties a slot is a named infeasibility" do
    payload = %{
      "days" => ["2026-09-07"],
      "slots" => ["lunch"],
      "constraints" => %{"weekly_budget_cents" => 500},
      "candidates_by_slot" => %{
        "lunch" => [Map.put(candidate("satay", 100, 300), "violates_restriction", true)]
      }
    }

    assert payload |> solve() |> Contract.interpret() ==
             {:infeasible, [%{cause: :restriction, slot: "lunch"}]}
  end

  defp candidate(id, cost, kcal) do
    %{
      "recipe_id" => id,
      "estimated_cost_cents" => cost,
      "calories_per_serving" => kcal,
      "protein_g_per_serving" => 0,
      "carbs_g_per_serving" => 0,
      "fat_g_per_serving" => 0
    }
  end

  defp solve(payload) do
    {:ok, port} = OptimizerPortRunner.open_port(python_executable: @python)

    try do
      Port.command(port, ~s({"type":"handshake","version":"1.0"}\n))
      Port.command(port, Jason.encode!(%{"type" => "solve", "id" => "t-1", "payload" => payload}))
      Port.command(port, "\n")

      case await(port, "", 2) do
        %{"type" => "solution", "result" => result} -> {:ok, result}
        %{"type" => "error", "error" => reason} = frame -> {:error, reason, frame["details"]}
      end
    after
      Port.close(port)
    end
  end

  # Returns the second protocol frame (the first is the handshake reply).
  defp await(port, buffer, frames_left) do
    case :binary.split(buffer, "\n") do
      [line, rest] ->
        frame = Jason.decode!(line)
        if frames_left == 1, do: frame, else: await(port, rest, frames_left - 1)

      [_incomplete] ->
        receive do
          {^port, {:data, data}} -> await(port, buffer <> data, frames_left)
        after
          30_000 -> flunk("optimizer did not answer")
        end
    end
  end
end
