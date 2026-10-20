defmodule MealPlannerApi.Services.PlanningChatService do
  @moduledoc """
  Quick favorites for the planning screen.

  Menu generation and the legacy proposal reject flow were switched off in
  issue #110: plans are produced only by the culinary agent.
  """

  alias MealPlannerApi.Data.RecipeRepo
  alias MealPlannerApi.Persistence.Identity

  # -------------------------------------------------------------------------
  # Quick favorites
  # -------------------------------------------------------------------------

  @spec quick_favorites(map(), non_neg_integer()) :: {:ok, [map()]} | {:error, term()}
  def quick_favorites(current_user, limit \\ 10) do
    with {:ok, ids} <- Identity.ensure_persistent_identity(current_user) do
      recipes =
        RecipeRepo.list_favorites(ids.account_id)
        |> Enum.take(limit)
        |> Enum.map(fn recipe ->
          %{
            recipe_id: recipe.id,
            recipe_name: recipe.name,
            slots:
              Enum.map(recipe.suitable_for_slots || [], fn
                slot when is_atom(slot) -> Atom.to_string(slot)
                slot when is_binary(slot) -> slot
              end),
            prep_time_minutes: recipe.prep_time_minutes,
            calories_per_serving: recipe.calories_per_serving
          }
        end)

      {:ok, recipes}
    end
  end
end
