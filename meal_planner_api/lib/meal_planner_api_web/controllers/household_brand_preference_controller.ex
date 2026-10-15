defmodule MealPlannerApiWeb.HouseholdBrandPreferenceController do
  @moduledoc """
  Household settings: Brand Preferences (issue #101, spec #93). This is also
  the target of the planning chat's "keep this brand" shortcut: a lasting
  brand choice is made here, never from the chat.

    * `GET /api/accounts/:account_id/settings/brand-preferences`
    * `PUT /api/accounts/:account_id/settings/brand-preferences/:ingredient_id`
      with `{"brand": "..."}`
    * `DELETE /api/accounts/:account_id/settings/brand-preferences/:ingredient_id`

  Any active Member of the Household may read or change them.
  Cross-Household access is rejected upstream by `EnforceAccountScope`
  (`403 account_mismatch`); the Household id used here always comes from
  `conn.assigns.current_membership`.
  """

  use MealPlannerApiWeb, :controller

  alias MealPlannerApi.BrandPreferences

  def index(conn, _params) do
    json(conn, %{data: BrandPreferences.list(household_id(conn))})
  end

  def update(conn, %{"ingredient_id" => ingredient_id} = params) do
    with {:ok, ingredient_id} <- Ecto.UUID.cast(ingredient_id),
         brand when is_binary(brand) <- Map.get(params, "brand"),
         {:ok, preference} <- BrandPreferences.put(household_id(conn), ingredient_id, brand) do
      json(conn, %{data: preference})
    else
      {:error, %Ecto.Changeset{} = changeset} -> invalid(conn, errors(changeset))
      _ -> invalid(conn, %{})
    end
  end

  def delete(conn, %{"ingredient_id" => ingredient_id}) do
    case Ecto.UUID.cast(ingredient_id) do
      {:ok, ingredient_id} ->
        :ok = BrandPreferences.delete(household_id(conn), ingredient_id)
        send_resp(conn, :no_content, "")

      :error ->
        invalid(conn, %{})
    end
  end

  defp invalid(conn, details) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "invalid_brand_preference", details: details})
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
