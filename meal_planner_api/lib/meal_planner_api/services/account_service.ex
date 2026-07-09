defmodule MealPlannerApi.Services.AccountService do
  @moduledoc """
  Account and user management orchestration.

  Phase A — Tenancy Refactor (PR 1). The legacy `account.users`
  association was removed when the canonical tenancy was moved onto
  `account.memberships`. This module now treats the membership roster
  as the source of truth: every consumer that previously walked
  `account.users` walks `account.memberships` and pulls the user record
  off each membership.
  """

  alias MealPlannerApi.Data.AccountRepo
  alias MealPlannerApi.Persistence.Identity

  @spec me(map()) :: {:ok, map()} | {:error, term()}
  def me(user) do
    # Phase A — PR 1: the canonical lookup is `account.memberships |> active
    # |> first |> .user.id`. For freshly-registered accounts that have not
    # yet had an AccountMembership row inserted (PR 2 task 2.10 will make
    # `register_with_password/1` atomic), we fall back to a User-by-id
    # lookup so the `/api/me` endpoint keeps working during the cutover
    # window. Once PR 2 lands the atomic registration, the fallback is
    # unreachable for new accounts but kept for legacy rows that pre-date
    # the backfill migration.
    identity =
      cond do
        is_binary(user.account_id) ->
          case AccountRepo.get_account_with_users!(user.account_id) do
            %{memberships: [_ | _] = memberships} ->
              case first_active_user(memberships) do
                nil -> fallback_to_user_lookup(user)
                user_record -> {:ok, %{account_id: user.account_id, user_id: user_record.id}}
              end

            _ ->
              fallback_to_user_lookup(user)
          end

        is_binary(user.id) ->
          fallback_to_user_lookup(user)

        true ->
          Identity.ensure_persistent_identity(user)
      end

    case identity do
      {:ok, %{account_id: account_id} = success} ->
        case AccountRepo.get_account_with_users!(account_id) do
          account when not is_nil(account) ->
            {:ok, Map.put(success, :account, serialize_account(account))}

          nil ->
            {:error, :account_not_found}
        end

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    Ecto.NoResultsError ->
      {:error, :account_not_found}
  end

  defp first_active_user(memberships) do
    case Enum.find(memberships, &(&1.status == :active)) do
      nil -> nil
      %{user: %{id: id} = user_record} when not is_nil(id) -> user_record
      _ -> nil
    end
  end

  defp fallback_to_user_lookup(%{user_id: user_id}) when is_binary(user_id) do
    case AccountRepo.get_user(user_id) do
      nil -> {:error, :account_not_found}
      %{account_id: account_id} -> {:ok, %{account_id: account_id, user_id: user_id}}
    end
  end

  defp fallback_to_user_lookup(_), do: {:error, :account_not_found}

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
               active_users: active_users_from_memberships(account)
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
    end
  end

  @spec remove_excluded_ingredient(map(), pos_integer()) :: :ok | {:error, term()}
  def remove_excluded_ingredient(user, ingredient_id) do
    case Identity.ensure_persistent_identity(user) do
      {:ok, _identity} ->
        AccountRepo.remove_excluded_ingredient(user.id, ingredient_id)
        :ok
    end
  end

  @spec list_excluded_ingredients(map()) :: {:ok, [map()]} | {:error, term()}
  def list_excluded_ingredients(user) do
    case Identity.ensure_persistent_identity(user) do
      {:ok, identity} ->
        ingredients = AccountRepo.list_excluded_ingredients(identity.user_id)
        {:ok, Enum.map(ingredients, &serialize_ingredient/1)}
    end
  end

  # -------------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------------

  defp serialize_account(a) do
    plan = Map.get(a, :plan, :individual)
    plan_string = plan |> to_string()

    %{
      id: a.id,
      name: a.name,
      plan: plan_string,
      account_type: legacy_account_type_for_plan(plan_string),
      subscription_tier: Atom.to_string(Map.get(a, :subscription_tier) || :free),
      default_budget_cents: a.default_budget_cents,
      created_at: iso_datetime(a.inserted_at)
    }
  end

  defp legacy_account_type_for_plan("individual"), do: "individual"
  defp legacy_account_type_for_plan(_), do: "group"

  defp active_users_from_memberships(account) do
    account.memberships
    |> Enum.filter(&(&1.status == :active))
    |> Enum.map(fn membership -> membership.user end)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&serialize_user/1)
  end

  defp serialize_user(u) do
    %{
      id: u.id,
      name: u.name,
      email: u.email,
      is_owner: false
    }
  end

  defp serialize_subscription(identity) do
    %{
      user_id: identity.user_id,
      account_id: identity.account_id,
      plan: Map.get(identity, :plan, "individual"),
      account_type: Map.get(identity, :account_type, "individual"),
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
