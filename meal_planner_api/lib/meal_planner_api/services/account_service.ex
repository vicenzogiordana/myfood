defmodule MealPlannerApi.Services.AccountService do
  @moduledoc """
  Account and user management orchestration.
  """

  alias MealPlannerApi.Data.AccountRepo
  alias MealPlannerApi.Persistence.Identity

  @spec me(map()) :: {:ok, map()} | {:error, term()}
  def me(user) do
    identity =
      cond do
        is_binary(user.account_id) ->
          # Has account_id — use it directly, find user from account
          case AccountRepo.get_account_with_users!(user.account_id) do
            account when not is_nil(account) and account.users != [] ->
              user_record = List.first(account.users)
              {:ok, %{account_id: user.account_id, user_id: user_record.id}}

            _ ->
              {:error, :account_not_found}
          end

        is_binary(user.id) ->
          Identity.ensure_persistent_identity(user)

        true ->
          Identity.ensure_persistent_identity(user)
      end

    case identity do
      {:ok, %{account_id: account_id}} ->
        case AccountRepo.get_account_with_users!(account_id) do
          account when not is_nil(account) -> {:ok, serialize_account(account)}
          nil -> {:error, :account_not_found}
        end

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    Ecto.NoResultsError ->
      {:error, :account_not_found}
  end

  @spec context(map()) :: {:ok, map()} | {:error, term()}
  def context(user) do
    case Identity.ensure_persistent_identity(user) do
      {:ok, identity} ->
        case AccountRepo.get_account_with_users!(identity.account_id) do
          account when not is_nil(account) ->
            {:ok,
             %{
               account: serialize_account(account),
               subscription: serialize_subscription(identity),
               active_users: Enum.map(account.users || [], &serialize_user/1)
             }}

          nil ->
            {:error, :account_not_found}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec update_dietary_profile(map(), map()) :: {:ok, map()} | {:error, term()}
  def update_dietary_profile(user, attrs) do
    case Identity.ensure_persistent_identity(user) do
      {:ok, identity} ->
        case AccountRepo.upsert_dietary_profile(identity.user_id, attrs) do
          {:ok, profile} -> {:ok, serialize_dietary_profile(profile)}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec add_excluded_ingredient(map(), pos_integer()) :: {:ok, map()} | {:error, term()}
  def add_excluded_ingredient(user, ingredient_id) do
    case Identity.ensure_persistent_identity(user) do
      {:ok, identity} ->
        case AccountRepo.add_excluded_ingredient(identity.user_id, ingredient_id, "manual") do
          {:ok, _excluded} -> {:ok, %{ingredient_id: ingredient_id, excluded: true}}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec remove_excluded_ingredient(map(), pos_integer()) :: :ok | {:error, term()}
  def remove_excluded_ingredient(user, ingredient_id) do
    case Identity.ensure_persistent_identity(user) do
      {:ok, identity} ->
        AccountRepo.remove_excluded_ingredient(identity.user_id, ingredient_id)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec list_excluded_ingredients(map()) :: {:ok, [map()]} | {:error, term()}
  def list_excluded_ingredients(user) do
    case Identity.ensure_persistent_identity(user) do
      {:ok, identity} ->
        ingredients = AccountRepo.list_excluded_ingredients(identity.user_id)
        {:ok, Enum.map(ingredients, &serialize_ingredient/1)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # -------------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------------

  defp serialize_account(a) do
    %{
      id: a.id,
      name: a.name,
      account_type: Atom.to_string(a.account_type),
      subscription_tier: Atom.to_string(Map.get(a, :subscription_tier) || :free),
      default_budget_cents: a.default_budget_cents,
      created_at: iso_datetime(a.inserted_at)
    }
  end

  defp serialize_user(u) do
    %{
      id: u.id,
      name: u.name,
      email: u.email,
      is_owner: u.is_owner
    }
  end

  defp serialize_subscription(identity) do
    %{
      user_id: identity.user_id,
      account_id: identity.account_id,
      account_type: identity.account_type,
      subscription_tier: identity.subscription_tier
    }
  end

  defp serialize_dietary_profile(p) do
    %{
      id: p.id,
      user_id: p.user_id,
      kcal_target: p.kcal_target,
      macro_ratios: %{
        protein: p.protein_ratio,
        carbs: p.carbs_ratio,
        fat: p.fat_ratio
      },
      excluded_ingredient_ids: p.excluded_ingredient_ids || []
    }
  end

  defp serialize_ingredient(i) do
    %{
      id: i.id,
      name: i.name,
      category: Atom.to_string(i.category)
    }
  end

  defp iso_datetime(nil), do: nil
  defp iso_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp iso_datetime(%Date{} = d), do: Date.to_iso8601(d)
end
