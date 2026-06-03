defmodule MealPlannerApi.Persistence.Accounts do
  @moduledoc "Persistence helpers for accounts, users, dietary settings and RevenueCat state."

  import Ecto.Query, warn: false

  alias MealPlannerApi.Repo
  alias MealPlannerApi.Subscriptions

  alias MealPlannerApi.Persistence.Accounts.{
    Account,
    RevenuecatCustomer,
    RevenuecatEntitlement,
    RevenuecatSubscriptionSnapshot,
    RevenuecatWebhookEvent,
    User,
    UserDietaryProfile,
    UserExcludedIngredient
  }

  def create_account(attrs) do
    attrs =
      attrs
      |> ensure_map()
      |> maybe_put_default_subscription_plan_id()

    %Account{} |> Account.changeset(attrs) |> Repo.insert()
  end

  def get_account(id), do: Repo.get(Account, id)

  def get_account!(id), do: Repo.get!(Account, id)

  def get_account_with_users!(id), do: Account |> Repo.get!(id) |> Repo.preload(:users)

  def create_user(attrs), do: %User{} |> User.changeset(attrs) |> Repo.insert()

  def get_user(id), do: Repo.get(User, id)

  def get_user!(id), do: Repo.get!(User, id)

  def upsert_user_dietary_profile(user_id, attrs) do
    attrs = Map.put(attrs, :user_id, user_id)

    case Repo.get_by(UserDietaryProfile, user_id: user_id) do
      nil -> %UserDietaryProfile{} |> UserDietaryProfile.changeset(attrs) |> Repo.insert()
      profile -> profile |> UserDietaryProfile.changeset(attrs) |> Repo.update()
    end
  end

  def add_user_excluded_ingredient(user_id, ingredient_id, reason) do
    attrs = %{user_id: user_id, ingredient_id: ingredient_id, reason: reason}

    %UserExcludedIngredient{}
    |> UserExcludedIngredient.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:reason, :updated_at]},
      conflict_target: [:user_id, :ingredient_id]
    )
  end

  def list_user_excluded_ingredient_ids(user_ids) when is_list(user_ids) do
    from(e in UserExcludedIngredient, where: e.user_id in ^user_ids, select: e.ingredient_id)
    |> Repo.all()
    |> MapSet.new()
  end

  def list_user_excluded_ingredients(user_id) do
    from(e in UserExcludedIngredient, where: e.user_id == ^user_id)
    |> Repo.all()
  end

  def upsert_revenuecat_customer(attrs) do
    %RevenuecatCustomer{}
    |> RevenuecatCustomer.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:account_id, :user_id, :updated_at]},
      conflict_target: [:rc_app_user_id]
    )
  end

  def get_revenuecat_customer_by_app_user_id(rc_app_user_id) when is_binary(rc_app_user_id) do
    from(c in RevenuecatCustomer,
      where: c.rc_app_user_id == ^rc_app_user_id,
      limit: 1
    )
    |> Repo.one()
  end

  def upsert_revenuecat_entitlement(attrs) do
    # Normalize status → is_active for backwards compatibility
    attrs =
      cond do
        Map.has_key?(attrs, :is_active) -> attrs
        Map.has_key?(attrs, "is_active") -> attrs
        Map.get(attrs, "status") == "active" -> Map.put(attrs, :is_active, true)
        Map.get(attrs, "status") == "inactive" -> Map.put(attrs, :is_active, false)
        true -> attrs
      end

    %RevenuecatEntitlement{}
    |> RevenuecatEntitlement.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace_all_except, [:id, :inserted_at]},
      conflict_target: [:account_id, :entitlement_id]
    )
  end

  def list_active_revenuecat_entitlements_for_account(account_id, now \\ DateTime.utc_now()) do
    from(e in RevenuecatEntitlement,
      where: e.account_id == ^account_id and e.is_active == true,
      where:
        is_nil(e.expiration_date) or e.expiration_date > ^now or
          (not is_nil(e.grace_period_expires_date) and e.grace_period_expires_date > ^now),
      order_by: [desc: e.updated_at]
    )
    |> Repo.all()
  end

  def create_revenuecat_webhook_event(attrs) do
    %RevenuecatWebhookEvent{}
    |> RevenuecatWebhookEvent.changeset(attrs)
    |> Repo.insert()
  end

  def update_revenuecat_webhook_event(event, attrs) do
    event
    |> RevenuecatWebhookEvent.changeset(attrs)
    |> Repo.update()
  end

  def create_revenuecat_subscription_snapshot(attrs) do
    %RevenuecatSubscriptionSnapshot{}
    |> RevenuecatSubscriptionSnapshot.changeset(attrs)
    |> Repo.insert()
  end

  defp maybe_put_default_subscription_plan_id(attrs) do
    if Map.has_key?(attrs, :subscription_plan_id) do
      attrs
    else
      account_type = Map.get(attrs, :account_type, :individual)

      case Subscriptions.ensure_default_plan_id(account_type) do
        {:ok, plan_id} -> Map.put(attrs, :subscription_plan_id, plan_id)
        {:error, _} -> attrs
      end
    end
  end

  defp ensure_map(attrs) when is_map(attrs), do: attrs
end
