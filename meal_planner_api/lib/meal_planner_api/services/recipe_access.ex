defmodule MealPlannerApi.Services.RecipeAccess do
  @moduledoc "Live membership and subscription authorization for recipe and cooking access."
  import Ecto.Query
  alias MealPlannerApi.{AccountAccess, Repo}
  alias MealPlannerApi.Persistence.Accounts.AccountMembership

  def authorize(%{id: user_id, account_id: account_id}) do
    with {:ok, _} <- Ecto.UUID.cast(user_id),
         {:ok, _} <- Ecto.UUID.cast(account_id),
         true <-
           Repo.exists?(
             from(m in AccountMembership,
               where:
                 m.user_id == ^user_id and m.account_id == ^account_id and m.status == :active
             )
           ),
         true <- AccountAccess.eligible?(account_id) do
      {:ok, %{user_id: user_id, account_id: account_id}}
    else
      _ -> {:error, :subscription_required}
    end
  end

  def authorize(_), do: {:error, :subscription_required}
end
