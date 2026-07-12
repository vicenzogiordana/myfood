defmodule MealPlannerApi.Persistence.Identity do
  @moduledoc """
  Bridges auth identities to persistent UUID identities used by Ecto schemas.
  """

  import Ecto.Query, warn: false

  alias MealPlannerApi.Repo
  alias MealPlannerApi.Persistence.Accounts.{Account, AccountMembership, User}

  @spec ensure_persistent_identity(map()) ::
          {:ok, %{account_id: Ecto.UUID.t(), user_id: Ecto.UUID.t()}}
          | {:error, Ecto.Changeset.t() | :invalid_identity}
  def ensure_persistent_identity(%{id: external_user_id, account_id: external_account_id} = user)
      when is_binary(external_user_id) and is_binary(external_account_id) do
    case fetch_existing_identity(external_user_id, external_account_id) do
      {:ok, ids} ->
        {:ok, ids}

      :not_found ->
        with {:ok, account_id} <- stable_uuid("account:" <> external_account_id),
             {:ok, user_id} <- stable_uuid("user:" <> external_user_id),
             {:ok, _account} <- ensure_account(account_id, user),
             {:ok, _user} <- ensure_user(user_id, account_id, user) do
          {:ok, %{account_id: account_id, user_id: user_id}}
        end
    end
  end

  def ensure_persistent_identity(_), do: {:error, :invalid_identity}

  defp fetch_existing_identity(user_id, account_id) do
    with {:ok, _} <- Ecto.UUID.cast(user_id),
         {:ok, _} <- Ecto.UUID.cast(account_id),
         %Account{} <- Repo.get(Account, account_id),
         %User{} = user <- Repo.get(User, user_id),
         true <-
           legacy_account_match?(user, account_id) or active_membership?(user_id, account_id) do
      {:ok, %{account_id: account_id, user_id: user_id}}
    else
      _ -> :not_found
    end
  end

  # Phase A — Tenancy Refactor (PR 3c task 3.21, prerequisite fix).
  #
  # This bridge predates the `AccountMembership` model — its only
  # original fast path was "the real `users.account_id` column equals
  # the target account" (`legacy_account_match?/2`). Per design.md §2.3
  # (decision 5.1), `users.account_id` is intentionally nil for real
  # multi-membership Users going forward — `current_membership` carries
  # tenancy instead. Without also checking for a real, `:active`
  # `AccountMembership` row here, every service still routing through
  # `ensure_persistent_identity/1` (cooking_service, inventory_service,
  # planning_chat_service, shopping_service, recipe_service) would fall
  # through to the "mint a shadow User" branch below for ANY real
  # multi-membership User — inserting a second `users` row with the same
  # email and crashing on the `users.email` unique index. Both checks are
  # kept (`or`) so the legacy `find_or_create_identity/1` single-account
  # flow (which still sets `users.account_id` directly) is unaffected.
  defp legacy_account_match?(%User{account_id: account_id}, account_id), do: true
  defp legacy_account_match?(_user, _account_id), do: false

  defp active_membership?(user_id, account_id) do
    Repo.exists?(
      from(m in AccountMembership,
        where: m.user_id == ^user_id and m.account_id == ^account_id and m.status == :active
      )
    )
  end

  defp ensure_account(account_id, user) do
    attrs = %{
      name: map_user_name(user),
      plan: Map.get(user, :plan, :individual),
      default_budget_cents: 0
    }

    case Repo.get(Account, account_id) do
      nil ->
        %Account{id: account_id}
        |> Account.changeset(attrs)
        |> Repo.insert()

      account ->
        account
        |> Account.changeset(attrs)
        |> Repo.update()
    end
  end

  defp ensure_user(user_id, account_id, user) do
    attrs = %{
      account_id: account_id,
      email: Map.get(user, :email, "#{user_id}@myfood.local"),
      name: map_user_name(user),
      role: :owner
    }

    case Repo.get(User, user_id) do
      nil ->
        %User{id: user_id}
        |> User.changeset(attrs)
        |> Repo.insert()

      persisted_user ->
        persisted_user
        |> User.changeset(attrs)
        |> Repo.update()
    end
  end

  defp stable_uuid(value) do
    <<a1::32, a2::16, a3::16, a4::16, a5::48, _::binary>> = :crypto.hash(:sha256, value)

    part3 = Bitwise.bor(Bitwise.band(a3, 0x0FFF), 0x4000)
    part4 = Bitwise.bor(Bitwise.band(a4, 0x3FFF), 0x8000)

    uuid =
      [
        Integer.to_string(a1, 16) |> String.pad_leading(8, "0"),
        Integer.to_string(a2, 16) |> String.pad_leading(4, "0"),
        Integer.to_string(part3, 16) |> String.pad_leading(4, "0"),
        Integer.to_string(part4, 16) |> String.pad_leading(4, "0"),
        Integer.to_string(a5, 16) |> String.pad_leading(12, "0")
      ]
      |> Enum.join("-")

    Ecto.UUID.cast(uuid)
  end

  defp map_user_name(user) do
    case Map.get(user, :name) do
      name when is_binary(name) and name != "" -> name
      _ -> "MyFood User"
    end
  end
end
