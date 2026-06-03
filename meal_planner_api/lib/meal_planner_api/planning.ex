defmodule MealPlannerApi.Planning do
  @moduledoc """
  Compatibility shim — delegates to #{inspect(MealPlannerApi.Services.PlanningService)}.

  Deprecated: use `MealPlannerApi.Services.PlanningService` directly.
  """

  alias MealPlannerApi.Services.PlanningService
  alias MealPlannerApi.Persistence.Catalog.Recipe, as: CatalogRecipe
  alias MealPlannerApi.Repo

  @doc """
  Generates a weekly plan for the given user.

  ## Parameters
    - `user` — user map (must have :subscription_tier, :account_type keys)
    - `params` — map with optional keys: "days", "weekly_budget_cents", "kcal_target"

  Returns `{:ok, %{days: [...], max_planning_days: integer()}}`
  """
  @spec weekly_plan_for(map(), map()) ::
          {:ok, %{days: [map()], max_planning_days: pos_integer()}}
          | {:error,
             :exceeds_max_planning_days | :identity_resolution_failed | :optimization_failed}
  def weekly_plan_for(user, params) do
    max_days =
      case user do
        %{subscription_tier: :premium} -> 7
        %{subscription_tier: "premium"} -> 7
        _ -> 5
      end

    # Si "days" es un entero, validar que no exceda el máximo
    requested_days = Map.get(params, "days")

    if is_integer(requested_days) and requested_days > max_days do
      {:error, :exceeds_max_planning_days}
    else
      safe_params =
        if is_integer(requested_days) do
          # Si es un entero, pasar lista para que Enum.take no falle
          Map.put(params, "days", List.wrap(requested_days))
        else
          params
        end

      case PlanningService.generate_weekly_plan(user, safe_params) do
        {:ok, result} ->
          {:ok, result}

        {:error, _reason} ->
          {:error, :optimization_failed}
      end
    end
  end

  @doc """
  Persists scheduled meals for a user from a meal plan proposal.

  ## Parameters
    - `user` — user map (must have :id key for user_id)
    - `payload` — map with "meals" key, each meal having "date", "slot", "recipe_id"

  Returns `{:ok, %{scheduled_meals_count: integer()}}` or `{:error, :recipe_not_found}`
  """
  @spec confirm_plan(map(), map()) ::
          {:ok, %{scheduled_meals_count: non_neg_integer()}}
          | {:error, :recipe_not_found | :persistence_failed}
  def confirm_plan(user, payload) do
    account_id = Map.get(user, :account_id) || raise "user must have :account_id"
    user_id = Map.get(user, :id) || raise "user must have :id"
    meals = Map.get(payload, "meals", [])

    with :ok <- validate_recipes_exist(meals),
         {:ok, %{proposal_id: _proposal_id, meal_ids: meal_ids}} <-
           PlanningService.save_plan(account_id, user_id, meals) do
      {:ok, %{scheduled_meals_count: length(meal_ids)}}
    else
      {:error, :recipe_not_found} = error ->
        error

      {:error, _reason} ->
        {:error, :persistence_failed}
    end
  end

  defp validate_recipes_exist(meals) do
    recipe_ids = Enum.map(meals, & &1["recipe_id"])

    if Enum.all?(recipe_ids, &is_binary/1) and recipe_ids != [] do
      # Check at least one recipe exists
      first_id = List.first(recipe_ids)
      recipe = Repo.get(CatalogRecipe, first_id)

      if recipe do
        :ok
      else
        {:error, :recipe_not_found}
      end
    else
      {:error, :recipe_not_found}
    end
  end
end
