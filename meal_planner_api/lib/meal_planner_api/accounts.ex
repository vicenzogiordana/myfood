defmodule MealPlannerApi.Accounts do
  @moduledoc """
  Accounts context implementing individual vs group business rules.
  """

  alias MealPlannerApi.Repo
  alias MealPlannerApi.Accounts.Account
  alias MealPlannerApi.Persistence.Accounts.Account, as: PersistenceAccount
  alias MealPlannerApi.Persistence.Accounts.User, as: PersistenceUser

  @spec find_or_create_identity(map()) ::
          {:ok, %{user: PersistenceUser.t(), account: PersistenceAccount.t()}} | {:error, atom()}
  def find_or_create_identity(params) when is_map(params) do
    user_id = Map.get(params, "user_id", "user_1")
    account_id = Map.get(params, "account_id", "acct_#{user_id}")
    type = normalize_account_type(Map.get(params, "account_type", "individual"))

    with {:ok, db_account_id} <- stable_uuid("account:" <> account_id),
         {:ok, db_user_id} <- stable_uuid("user:" <> user_id),
         {:ok, account} <- upsert_account(db_account_id, type, params),
         {:ok, user} <- upsert_user(db_user_id, db_account_id, params) do
      {:ok, %{user: user, account: account}}
    else
      _ -> {:error, :unable_to_issue_identity}
    end
  end

  @spec link_user(Account.t(), String.t()) ::
          {:ok, Account.t()} | {:error, :individual_limit_reached}
  def link_user(%Account{type: :group} = account, user_id) when is_binary(user_id) do
    {:ok, %{account | linked_user_ids: Enum.uniq([user_id | account.linked_user_ids])}}
  end

  def link_user(%Account{type: :individual} = account, user_id) when is_binary(user_id) do
    if can_link_user?(account) do
      {:ok, %{account | linked_user_ids: [user_id]}}
    else
      {:error, :individual_limit_reached}
    end
  end

  @spec can_link_user?(Account.t()) :: boolean()
  def can_link_user?(%Account{type: :group}), do: true
  def can_link_user?(%Account{type: :individual, linked_user_ids: linked}), do: linked == []

  @spec claims_for(map(), map()) :: map()
  def claims_for(user, account) when is_map(user) and is_map(account) do
    account_type = account_type_from(account)
    subscription_tier = subscription_tier_from(user)

    %{
      "account_id" => account.id,
      "account_type" => Atom.to_string(account_type),
      "subscription_tier" => Atom.to_string(subscription_tier),
      "email" => user.email,
      "name" => user.name,
      "linked_user_ids" => Map.get(account, :linked_user_ids, [])
    }
  end

  @spec serialize_user(map()) :: map()
  def serialize_user(user) when is_map(user) do
    %{
      id: user.id,
      account_id: user.account_id,
      email: user.email,
      name: user.name,
      account_type: Map.get(user, :account_type, :individual),
      subscription_tier: subscription_tier_from(user)
    }
  end

  @spec serialize_account(map()) :: map()
  def serialize_account(account) when is_map(account) do
    type = account_type_from(account)

    %{
      id: account.id,
      type: type,
      owner_id: Map.get(account, :owner_id),
      subscription_tier: subscription_tier_from(account),
      linked_user_ids: Map.get(account, :linked_user_ids, []),
      max_linked_users: if(type == :group, do: :unlimited, else: 1)
    }
  end

  defp normalize_account_type("group"), do: :group
  defp normalize_account_type(:group), do: :group
  defp normalize_account_type(_), do: :individual

  defp upsert_account(db_account_id, type, params) do
    attrs = %{
      name: Map.get(params, "name", "MyFood User"),
      account_type: type,
      default_budget_cents: 0
    }

    case Repo.get(PersistenceAccount, db_account_id) do
      nil ->
        %PersistenceAccount{id: db_account_id}
        |> PersistenceAccount.changeset(attrs)
        |> Repo.insert()

      account ->
        account
        |> PersistenceAccount.changeset(attrs)
        |> Repo.update()
    end
  end

  defp upsert_user(db_user_id, db_account_id, params) do
    attrs = %{
      account_id: db_account_id,
      email: Map.get(params, "email", "#{db_user_id}@myfood.local"),
      name: Map.get(params, "name", "MyFood User"),
      role: :owner
    }

    case Repo.get(PersistenceUser, db_user_id) do
      nil ->
        %PersistenceUser{id: db_user_id}
        |> PersistenceUser.changeset(attrs)
        |> Repo.insert()

      user ->
        user
        |> PersistenceUser.changeset(attrs)
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

  defp account_type_from(account) do
    Map.get(account, :type) || Map.get(account, :account_type, :individual)
  end

  defp subscription_tier_from(entity) do
    Map.get(entity, :subscription_tier, :free)
  end
end
