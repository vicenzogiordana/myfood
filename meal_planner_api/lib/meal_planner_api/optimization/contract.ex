defmodule MealPlannerApi.Optimization.Contract do
  @moduledoc """
  Elixir side of the optimizer v2 contract (spec #93, issues #97 and #98; see
  `docs/OPTIMIZER_CONTRACT.md`).

  The OR-Tools optimizer (CP-SAT backend, OR-Tools pinned in
  `requirements.txt`) always returns the closest plan with a per-goal
  Deviation report. Only the budget, daily calories and daily macros relax, in
  the fixed priority budget > calories > macros; coverage, Restrictions,
  Excluded Recipes and the variety rules (`MealPlannerApi.Optimization.Variety`)
  never relax.

  This module builds the nutrition part of a request from the Household
  Nutrition Goal and turns optimizer replies into typed outcomes:

    * `{:ok, plan}` — `meals`, exact `deviations` (priority order) and
      `optimality` (`:optimal`, or `:feasible` when not proven optimal and to
      be disclosed)
    * `{:infeasible, causes}` — each cause names a hard rule
      (`:coverage`, `:restriction`, `:excluded_recipe`) and its slot, or is
      `%{cause: :variety, slot: nil}` when the variety rules cannot be met
    * `{:inconclusive, :time_limit | :deadline}` — the solver or the caller
      ran out of time; never infeasible
    * `{:error, reason}` — any other failure, including malformed replies
  """

  @nutrition_goals [:calories, :protein_g, :carbs_g, :fat_g]
  @goals Map.new([:budget | @nutrition_goals], &{Atom.to_string(&1), &1})
  @directions %{"above_max" => :above_max, "below_min" => :below_min}
  @optimality %{"optimal" => :optimal, "feasible" => :feasible}
  @causes %{
    "coverage" => :coverage,
    "restriction" => :restriction,
    "excluded_recipe" => :excluded_recipe,
    "variety" => :variety
  }
  @passthrough_errors [:optimizer_unavailable, :optimizer_crashed, :solver_unavailable]

  @type meal :: %{date: Date.t(), slot: String.t(), recipe_id: String.t()}
  @type deviation :: %{
          goal: :budget | :calories | :protein_g | :carbs_g | :fat_g,
          priority: 1 | 2 | 3,
          day: Date.t() | nil,
          direction: :above_max | :below_min,
          bound: number(),
          actual: number(),
          amount: number()
        }
  @type plan :: %{
          meals: [meal()],
          deviations: [deviation()],
          optimality: :optimal | :feasible
        }
  @type cause :: %{
          cause: :coverage | :restriction | :excluded_recipe | :variety,
          slot: String.t() | nil
        }
  @type outcome ::
          {:ok, plan()}
          | {:infeasible, [cause()]}
          | {:inconclusive, :time_limit | :deadline}
          | {:error, atom()}

  @doc """
  Daily `constraints.macro_bounds` for the optimizer from a Household
  Nutrition Goal (as returned by `MealPlannerApi.NutritionGoals.get/1`), or
  `nil` when the Household has none, in which case only the budget can
  deviate.
  """
  @spec nutrition_bounds(map() | nil) :: map() | nil
  def nutrition_bounds(nil), do: nil

  def nutrition_bounds(goal) when is_map(goal) do
    Map.new(@nutrition_goals, fn key ->
      %{min: min, max: max} = Map.fetch!(goal, key)
      {Atom.to_string(key), %{"min" => min, "max" => max}}
    end)
  end

  @doc "Interprets one optimizer reply. See the module doc for the outcomes."
  @spec interpret(term()) :: outcome()
  def interpret({:ok, %{} = result}), do: plan(result)

  def interpret({:error, reason, details}), do: failure(reason, details)

  # `OptimizerServer` tags solver verdicts as `{reason, details}`.
  def interpret({:error, {reason, %{} = details}}) when is_atom(reason),
    do: failure(reason, details)

  def interpret({:error, reason}), do: failure(reason, %{})
  def interpret(_other), do: {:error, :invalid_optimizer_response}

  defp failure(reason, details) when is_atom(reason) and reason not in [nil, true, false],
    do: failure(Atom.to_string(reason), details)

  defp failure("infeasible", %{"causes" => causes}) when is_list(causes) do
    case map_all(causes, &cause/1) do
      {:ok, []} -> {:error, :invalid_optimizer_response}
      {:ok, parsed} -> {:infeasible, parsed}
      :error -> {:error, :invalid_optimizer_response}
    end
  end

  defp failure("infeasible", _details), do: {:error, :invalid_optimizer_response}
  defp failure("inconclusive", _details), do: {:inconclusive, :time_limit}
  defp failure("optimizer_timeout", _details), do: {:inconclusive, :deadline}

  defp failure(reason, _details) when is_binary(reason) do
    case Enum.find(@passthrough_errors, &(Atom.to_string(&1) == reason)) do
      nil -> {:error, :optimizer_error}
      known -> {:error, known}
    end
  end

  defp failure(_reason, _details), do: {:error, :optimizer_error}

  defp plan(%{"meals" => meals, "deviations" => deviations, "optimality" => optimality})
       when is_list(meals) and is_list(deviations) and is_map_key(@optimality, optimality) do
    with {:ok, meals} <- map_all(meals, &meal/1),
         {:ok, deviations} <- map_all(deviations, &deviation/1) do
      {:ok,
       %{
         meals: meals,
         deviations: Enum.sort_by(deviations, &{&1.priority, day_key(&1.day)}),
         optimality: Map.fetch!(@optimality, optimality)
       }}
    else
      :error -> {:error, :invalid_optimizer_response}
    end
  end

  defp plan(_result), do: {:error, :invalid_optimizer_response}

  defp meal(%{"day" => day, "slot" => slot, "recipe_id" => recipe_id})
       when is_binary(slot) and is_binary(recipe_id) do
    with {:ok, date} <- date(day), do: {:ok, %{date: date, slot: slot, recipe_id: recipe_id}}
  end

  defp meal(_meal), do: :error

  defp deviation(
         %{
           "goal" => goal,
           "priority" => priority,
           "direction" => direction,
           "bound" => bound,
           "actual" => actual,
           "amount" => amount
         } = raw
       )
       when is_map_key(@goals, goal) and is_map_key(@directions, direction) and
              priority in [1, 2, 3] and is_number(bound) and is_number(actual) and
              is_number(amount) do
    with {:ok, day} <- deviation_day(goal, Map.get(raw, "day")) do
      {:ok,
       %{
         goal: Map.fetch!(@goals, goal),
         priority: priority,
         day: day,
         direction: Map.fetch!(@directions, direction),
         bound: bound,
         actual: actual,
         amount: amount
       }}
    end
  end

  defp deviation(_deviation), do: :error

  # The budget covers the whole range; every nutrition Deviation is per day.
  defp deviation_day("budget", nil), do: {:ok, nil}
  defp deviation_day("budget", _day), do: :error
  defp deviation_day(_goal, day), do: date(day)

  # Variety spans days and slots, so it names no slot.
  defp cause(%{"cause" => "variety"} = raw) when not is_map_key(raw, "slot"),
    do: {:ok, %{cause: :variety, slot: nil}}

  defp cause(%{"cause" => cause, "slot" => slot})
       when is_map_key(@causes, cause) and is_binary(slot),
       do: {:ok, %{cause: Map.fetch!(@causes, cause), slot: slot}}

  defp cause(_cause), do: :error

  defp date(day) when is_binary(day) do
    case Date.from_iso8601(day) do
      {:ok, date} -> {:ok, date}
      _ -> :error
    end
  end

  defp date(_day), do: :error

  defp day_key(nil), do: ""
  defp day_key(%Date{} = date), do: Date.to_iso8601(date)

  defp map_all(items, fun) do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      :error -> :error
    end
  end
end
