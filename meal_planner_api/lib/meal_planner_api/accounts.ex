defmodule MealPlannerApi.Accounts do
  @moduledoc """
  Accounts context implementing individual vs group business rules.
  """

  alias MealPlannerApi.Accounts.{Account, User}
  alias MealPlannerApi.Subscriptions

  @spec issue_mock_identity(map()) ::
          {:ok, %{user: User.t(), account: Account.t()}} | {:error, atom()}
  def issue_mock_identity(params) when is_map(params) do
    user_id = Map.get(params, "user_id", "user_1")
    account_id = Map.get(params, "account_id", "acct_#{user_id}")
    type = normalize_account_type(Map.get(params, "account_type", "individual"))
    subscription_tier = Subscriptions.normalize_tier(Map.get(params, "subscription_tier", "free"))

    user = %User{
      id: user_id,
      account_id: account_id,
      email: Map.get(params, "email", "#{user_id}@myfood.local"),
      name: Map.get(params, "name", "MyFood User"),
      account_type: type,
      subscription_tier: subscription_tier
    }

    account =
      %Account{
        id: account_id,
        type: type,
        owner_id: user.id,
        linked_user_ids: [],
        subscription_tier: subscription_tier
      }
      |> maybe_link_users(Map.get(params, "linked_user_ids", []))

    {:ok, %{user: user, account: account}}
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

  @spec claims_for(User.t(), Account.t()) :: map()
  def claims_for(%User{} = user, %Account{} = account) do
    %{
      "account_id" => account.id,
      "account_type" => Atom.to_string(account.type),
      "subscription_tier" => Atom.to_string(account.subscription_tier),
      "email" => user.email,
      "name" => user.name,
      "linked_user_ids" => account.linked_user_ids
    }
  end

  @spec serialize_user(User.t()) :: map()
  def serialize_user(%User{} = user) do
    %{
      id: user.id,
      account_id: user.account_id,
      email: user.email,
      name: user.name,
      account_type: user.account_type,
      subscription_tier: user.subscription_tier
    }
  end

  @spec serialize_account(Account.t()) :: map()
  def serialize_account(%Account{} = account) do
    %{
      id: account.id,
      type: account.type,
      owner_id: account.owner_id,
      subscription_tier: account.subscription_tier,
      linked_user_ids: account.linked_user_ids,
      max_linked_users: if(account.type == :group, do: :unlimited, else: 1)
    }
  end

  defp normalize_account_type("group"), do: :group
  defp normalize_account_type(:group), do: :group
  defp normalize_account_type(_), do: :individual

  defp maybe_link_users(account, linked_user_ids) when is_list(linked_user_ids) do
    Enum.reduce(linked_user_ids, account, fn user_id, acc ->
      case link_user(acc, user_id) do
        {:ok, updated} -> updated
        {:error, _} -> acc
      end
    end)
  end

  defp maybe_link_users(account, _), do: account
end
