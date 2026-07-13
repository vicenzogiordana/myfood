defmodule MealPlannerApi.Optimization.OptimizerPort do
  @moduledoc """
  Behaviour for the meal optimization integration.

  Implementors must provide a way to select a weekly menu given candidate
  recipes, nutritional constraints, and budget limits.

  The port may raise an error for:
  - `:optimizer_timeout` — solver did not respond in time
  - `:optimizer_unavailable` — process is down or circuit is open
  - `:optimizer_error` — solver returned an error (e.g. malformed input)
  """

  @type optimizer_payload :: %{
          days: [String.t()],
          slots: [String.t()],
          constraints: optimizer_constraints(),
          candidates_by_slot: %{
            String.t() => [candidate_recipe()]
          }
        }

  @type optimizer_constraints :: %{
          kcal_target: integer(),
          weekly_budget_cents: integer(),
          account_type: String.t(),
          subscription_tier: String.t(),
          inventory_items: [String.t()],
          macro_bounds: macro_bounds()
        }

  @type optimizer_result :: {:ok, %{meals: [selected_meal()]}} | {:error, term()}

  @type macro_bounds :: %{
          protein_g: %{min: float(), max: float()},
          carbs_g: %{min: float(), max: float()},
          fat_g: %{min: float(), max: float()},
          calories: %{min: float(), max: float()}
        }

  @type candidate_recipe :: %{
          recipe_id: String.t(),
          slot: String.t(),
          label: String.t(),
          kcal: float(),
          estimated_cost_cents: integer(),
          inventory_hit_count: integer(),
          protein_g_per_serving: float(),
          carbs_g_per_serving: float(),
          fat_g_per_serving: float(),
          calories_per_serving: float()
        }

  @type selected_meal :: %{
          day: String.t(),
          slot: String.t(),
          recipe_id: String.t() | nil
        }

  @doc """
  Given a payload describing the planning request, returns a weekly plan.

  The result `meals` list must contain one entry per day × slot combination.
  """
  defmacro __using__(_opts) do
    quote do
      @behaviour unquote(__MODULE__)

      @impl true
      def health_check, do: :ok

      defmacro __before_compile__(env), do: :ok
    end
  end

  @callback select_weekly_menu(optimizer_payload()) :: optimizer_result()

  @doc """
  Returns `:ok` if the optimizer is running and ready to accept requests.
  """
  @callback health_check() :: :ok | {:error, :optimizer_unavailable}
end
