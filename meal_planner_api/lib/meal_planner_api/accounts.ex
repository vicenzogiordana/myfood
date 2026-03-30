defmodule MealPlannerApi.Accounts do
  @moduledoc """
  Accounts context implementing individual vs group business rules.
  """

  alias Ecto.Multi
  alias MealPlannerApi.Repo
  alias MealPlannerApi.Subscriptions
  alias MealPlannerApi.Accounts.Account
  alias MealPlannerApi.Persistence.Accounts.Account, as: PersistenceAccount
  alias MealPlannerApi.Persistence.Accounts.User, as: PersistenceUser

  @spec find_or_create_identity(map()) ::
          {:ok, %{user: PersistenceUser.t(), account: PersistenceAccount.t()}}
          | {:error, :missing_identity | :unable_to_issue_identity}
  def find_or_create_identity(params) when is_map(params) do
    with {:ok, user_id} <- fetch_required_identity(params, "user_id"),
         {:ok, account_id} <- fetch_required_identity(params, "account_id"),
         type <- normalize_account_type(Map.get(params, "account_type", "individual")),
         {:ok, db_account_id} <- stable_uuid("account:" <> account_id),
         {:ok, db_user_id} <- stable_uuid("user:" <> user_id),
         {:ok, account} <- upsert_account(db_account_id, type, params),
         {:ok, user} <- upsert_user(db_user_id, db_account_id, params) do
      {:ok, %{user: user, account: account}}
    else
      {:error, :missing_identity} -> {:error, :missing_identity}
      _ -> {:error, :unable_to_issue_identity}
    end
  end

  @spec register_with_password(map()) ::
          {:ok, %{user: PersistenceUser.t(), account: PersistenceAccount.t()}}
          | {:error,
             :email_already_registered
             | :invalid_email
             | :invalid_password
             | :password_too_short
             | :unable_to_issue_identity}
  def register_with_password(params) when is_map(params) do
    with {:ok, email} <- fetch_email(params),
         {:ok, password} <- fetch_password(params),
         :ok <- ensure_password_strength(password),
         nil <- user_by_email(email),
         type <- normalize_account_type(Map.get(params, "account_type", "individual")),
         {:ok, subscription_plan_id} <- Subscriptions.ensure_default_plan_id(type),
         password_hash <- Bcrypt.hash_pwd_salt(password),
         {:ok, result} <-
           create_account_and_user(email, password_hash, type, params, subscription_plan_id) do
      {:ok, %{user: result.user, account: result.account}}
    else
      %PersistenceUser{} -> {:error, :email_already_registered}
      {:error, _} = error -> error
      _ -> {:error, :unable_to_issue_identity}
    end
  end

  @spec authenticate_with_password(map()) ::
          {:ok, %{user: PersistenceUser.t(), account: PersistenceAccount.t()}}
          | {:error, :invalid_email | :invalid_password | :invalid_credentials}
  def authenticate_with_password(params) when is_map(params) do
    with {:ok, email} <- fetch_email(params),
         {:ok, password} <- fetch_password(params),
         %PersistenceUser{} = user <- user_by_email(email),
         true <- is_binary(user.password_hash) and user.password_hash != "",
         true <- Bcrypt.verify_pass(password, user.password_hash),
         %PersistenceAccount{} = account <- Repo.get(PersistenceAccount, user.account_id) do
      {:ok, %{user: user, account: account}}
    else
      nil ->
        Bcrypt.no_user_verify()
        {:error, :invalid_credentials}

      false ->
        Bcrypt.no_user_verify()
        {:error, :invalid_credentials}

      {:error, _} = error ->
        error

      _ ->
        Bcrypt.no_user_verify()
        {:error, :invalid_credentials}
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

  defp fetch_email(params) when is_map(params) do
    params
    |> Map.get("email")
    |> normalize_email()
    |> case do
      nil -> {:error, :invalid_email}
      email -> {:ok, email}
    end
  end

  defp fetch_password(params) when is_map(params) do
    case Map.get(params, "password") do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :invalid_password}
    end
  end

  defp ensure_password_strength(password) when is_binary(password) do
    if String.length(password) >= 8,
      do: :ok,
      else: {:error, :password_too_short}
  end

  defp create_account_and_user(email, password_hash, type, params, subscription_plan_id) do
    account_attrs = %{
      name: Map.get(params, "name", "MyFood User"),
      account_type: type,
      default_budget_cents: 0,
      subscription_plan_id: subscription_plan_id
    }

    user_attrs = %{
      email: email,
      name: Map.get(params, "name", "MyFood User"),
      role: :owner,
      password_hash: password_hash
    }

    transaction =
      Multi.new()
      |> Multi.insert(
        :account,
        PersistenceAccount.changeset(%PersistenceAccount{}, account_attrs)
      )
      |> Multi.insert(:user, fn %{account: account} ->
        attrs = Map.put(user_attrs, :account_id, account.id)
        PersistenceUser.changeset(%PersistenceUser{}, attrs)
      end)

    case Repo.transaction(transaction) do
      {:ok, %{account: account, user: user}} -> {:ok, %{account: account, user: user}}
      {:error, _step, _reason, _changes} -> {:error, :unable_to_issue_identity}
    end
  end

  defp user_by_email(email) when is_binary(email),
    do: Repo.get_by(PersistenceUser, email: email)

  defp normalize_email(value) when is_binary(value) do
    value = value |> String.trim() |> String.downcase()

    if String.contains?(value, "@") and value != "@",
      do: value,
      else: nil
  end

  defp normalize_email(_), do: nil

  defp fetch_required_identity(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :missing_identity}
    end
  end

  defp upsert_account(db_account_id, type, params) do
    with {:ok, subscription_plan_id} <- Subscriptions.ensure_default_plan_id(type) do
      attrs = %{
        name: Map.get(params, "name", "MyFood User"),
        account_type: type,
        default_budget_cents: 0,
        subscription_plan_id: subscription_plan_id
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
