defmodule MealPlannerApi.Auth.Guardian do
  @moduledoc """
  Guardian implementation used by both HTTP requests and WebSocket connections.
  """

  use Guardian, otp_app: :meal_planner_api

  alias MealPlannerApi.Accounts.User

  @impl true
  def subject_for_token(%User{id: id}, _claims), do: {:ok, id}
  def subject_for_token(%{id: id}, _claims) when is_binary(id), do: {:ok, id}
  def subject_for_token(_, _claims), do: {:error, :invalid_resource}

  @impl true
  def resource_from_claims(%{"sub" => id} = claims) do
    user =
      %User{
        id: id,
        account_id: Map.get(claims, "account_id", "acct_#{id}"),
        email: Map.get(claims, "email", "user@myfood.local"),
        name: Map.get(claims, "name", "MyFood User"),
        account_type: normalize_account_type(Map.get(claims, "account_type", "individual")),
        subscription_tier:
          normalize_subscription_tier(Map.get(claims, "subscription_tier", "free"))
      }

    {:ok, user}
  end

  def resource_from_claims(_claims), do: {:error, :invalid_claims}

  defp normalize_account_type("group"), do: :group
  defp normalize_account_type(:group), do: :group
  defp normalize_account_type(_), do: :individual

  defp normalize_subscription_tier("premium"), do: :premium
  defp normalize_subscription_tier(:premium), do: :premium
  defp normalize_subscription_tier(_), do: :free
end
