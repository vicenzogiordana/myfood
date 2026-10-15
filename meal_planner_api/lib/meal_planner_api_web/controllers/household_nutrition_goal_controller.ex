defmodule MealPlannerApiWeb.HouseholdNutritionGoalController do
  @moduledoc """
  Household settings: the Nutrition Goal (issue #95, spec #93).

  `GET` and `PUT /api/accounts/:account_id/settings/nutrition-goal`. Any
  active Member of the Household may read or replace it. Cross-Household
  access is rejected upstream by `EnforceAccountScope` (`403
  account_mismatch`); the Household id used here always comes from
  `conn.assigns.current_membership`.
  """

  use MealPlannerApiWeb, :controller

  alias MealPlannerApi.NutritionGoals

  @range_keys ~w(calories protein_g carbs_g fat_g)

  def show(conn, _params) do
    json(conn, %{data: NutritionGoals.get(household_id(conn))})
  end

  def update(conn, params) do
    case NutritionGoals.put(household_id(conn), Map.take(params, @range_keys)) do
      {:ok, goal} ->
        json(conn, %{data: goal})

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "invalid_nutrition_goal", details: errors(changeset)})
    end
  end

  defp household_id(conn), do: conn.assigns.current_membership.account_id

  defp errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
