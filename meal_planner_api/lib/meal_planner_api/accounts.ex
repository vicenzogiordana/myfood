defmodule MealPlannerApi.Accounts do
  @moduledoc """
  Accounts context implementing individual vs group business rules.

  Phase A — Tenancy Refactor (PR 1) swapped the legacy `:account_type`
  taxonomy (`:individual | :group`) for the canonical `Account.plan`
  enum (`:individual | :family_4 | :family_6 | :trial`). The legacy
  `account_type` field is gone from the `Account` schema and from
  `Accounts.claims_for/2`'s output keys; the JWT still carries
  `"account_type"` for backwards compatibility (derived from plan:
  `:individual` → "individual", everything else → "group") so existing
  consumers continue to work without an app release.
  """

  import Ecto.Query

  require Logger

  alias Ecto.Multi
  alias MealPlannerApi.Repo
  alias MealPlannerApi.Subscriptions
  alias MealPlannerApi.Accounts.Account
  alias MealPlannerApi.Persistence.Accounts.Account, as: PersistenceAccount
  alias MealPlannerApi.Persistence.Accounts.AccountMembership
  alias MealPlannerApi.Persistence.Accounts.User, as: PersistenceUser

  @plan_values [:individual, :family_4, :family_6, :trial]

  @spec find_or_create_identity(map()) ::
          {:ok, %{user: PersistenceUser.t(), account: PersistenceAccount.t()}}
          | {:error, :missing_identity | :unable_to_issue_identity}
  def find_or_create_identity(params) when is_map(params) do
    with {:ok, user_id} <- fetch_required_identity(params, "user_id"),
         {:ok, account_id} <- fetch_required_identity(params, "account_id"),
         plan <- normalize_plan(Map.get(params, "account_type", "individual")),
         {:ok, db_account_id} <- stable_uuid("account:" <> account_id),
         {:ok, db_user_id} <- stable_uuid("user:" <> user_id),
         {:ok, account} <- upsert_account(db_account_id, plan, params),
         {:ok, user} <- upsert_user(db_user_id, db_account_id, params) do
      {:ok, %{user: user, account: account}}
    else
      {:error, :missing_identity} -> {:error, :missing_identity}
      _ -> {:error, :unable_to_issue_identity}
    end
  end

  @spec register_with_password(map()) ::
          {:ok,
           %{
             user: PersistenceUser.t(),
             account: PersistenceAccount.t(),
             membership: AccountMembership.t()
           }}
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
         plan <- normalize_plan(Map.get(params, "account_type", "individual")),
         {:ok, subscription_plan_id} <- Subscriptions.ensure_default_plan_id(plan),
         password_hash <- Bcrypt.hash_pwd_salt(password),
         {:ok, result} <-
           create_account_and_user(email, password_hash, plan, params, subscription_plan_id) do
      {:ok, %{user: result.user, account: result.account, membership: result.membership}}
    else
      %PersistenceUser{} -> {:error, :email_already_registered}
      {:error, _} = error -> error
      _ -> {:error, :unable_to_issue_identity}
    end
  end

  @spec authenticate_with_password(map()) ::
          {:ok,
           %{
             user: PersistenceUser.t(),
             account: PersistenceAccount.t(),
             membership: AccountMembership.t() | nil
           }}
          | {:error, :invalid_email | :invalid_password | :invalid_credentials}
  def authenticate_with_password(params) when is_map(params) do
    with {:ok, email} <- fetch_email(params),
         {:ok, password} <- fetch_password(params),
         %PersistenceUser{} = user <- user_by_email(email),
         true <- is_binary(user.password_hash) and user.password_hash != "",
         true <- Bcrypt.verify_pass(password, user.password_hash),
         %PersistenceAccount{} = account <- Repo.get(PersistenceAccount, user.account_id) do
      membership = first_active_membership_for(user, account)

      {:ok, %{user: user, account: account, membership: membership}}
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

  @doc """
  Returns the seat usage for an Account-shaped DTO. In Phase A this is a
  placeholder (the canonical implementation lives in
  `MealPlannerApi.AccountsMembership.seat_usage/1` per design §6.2 / §10
  Q10 — landed in PR 2). The function exists here so callers can compile
  during the dual-write window.
  """
  @spec seat_usage(map()) :: %{active: non_neg_integer(), invited: non_neg_integer(), capacity: pos_integer()}
  def seat_usage(%{plan: plan}) when is_atom(plan) do
    %{active: 0, invited: 0, capacity: max_users_for_plan(plan)}
  end

  def seat_usage(_), do: %{active: 0, invited: 0, capacity: 1}

  @doc """
  Builds the legacy `access_v1` JWT claim map for the given user/account
  pair.

  Deliberately does NOT set a `"typ"` key. `Guardian.encode_and_sign/3`'s
  `token_type:` option only controls the minted `typ` claim when the
  claims map passed in has no (non-nil) `"typ"` key already — Guardian's
  `set_type/3` skips overriding an existing one. Every call site
  (`auth_controller.ex`) passes `token_type: "access"` or
  `token_type: "refresh"` explicitly; hardcoding `"typ" => "access"` here
  used to force every refresh token to carry `typ: "access"`, letting
  refresh tokens pass as access tokens anywhere behind `VerifyTokenType`.
  """
  @spec claims_for(map(), map()) :: map()
  def claims_for(user, account) when is_map(user) and is_map(account) do
    legacy_account_type = legacy_account_type_from_plan(plan_from(account))
    subscription_tier = subscription_tier_from(user)

    %{
      "account_id" => account.id,
      "account_type" => legacy_account_type,
      "subscription_tier" => Atom.to_string(subscription_tier),
      "email" => user.email,
      "name" => user.name,
      "linked_user_ids" => Map.get(account, :linked_user_ids, [])
    }
  end

  @spec serialize_user(map()) :: map()
  def serialize_user(user) when is_map(user) do
    %{
      id: to_string(user.id),
      account_id: to_string(Map.get(user, :account_id)),
      email: user.email,
      name: user.name,
      avatar_url: Map.get(user, :avatar_url),
      plan: Map.get(user, :plan, :individual),
      subscription_tier: subscription_tier_from(user)
    }
  end

  @spec serialize_account(map()) :: map()
  def serialize_account(account) when is_map(account) do
    plan = plan_from(account)

    %{
      id: account.id,
      plan: plan,
      owner_id: Map.get(account, :owner_id),
      subscription_tier: subscription_tier_from(account),
      linked_user_ids: Map.get(account, :linked_user_ids, []),
      max_linked_users: max_users_for_plan(plan)
    }
  end

  @doc """
  Normalizes an `account_type`-shaped API input (`:individual | :group` or
  their string forms) into the canonical `Account.plan` atom.

  * `:individual | "individual"` → `:individual`
  * `:group | "group"` → `:family_4` (per design §2.2 data migration)
  * `:family_4 | "family_4"` → `:family_4`
  * `:family_6 | "family_6"` → `:family_6`
  * `:trial | "trial"` → `:trial`
  * Anything else → `:individual`
  """
  @spec normalize_plan(term()) :: atom()
  def normalize_plan(plan) when plan in @plan_values, do: plan
  def normalize_plan(:group), do: :family_4
  def normalize_plan("group"), do: :family_4
  def normalize_plan("family_4"), do: :family_4
  def normalize_plan("family_6"), do: :family_6
  def normalize_plan("trial"), do: :trial
  def normalize_plan("individual"), do: :individual
  def normalize_plan(_), do: :individual

  # ---- private helpers -------------------------------------------------------

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

  defp create_account_and_user(email, password_hash, plan, params, subscription_plan_id) do
    account_attrs = %{
      name: Map.get(params, "name", "MyFood User"),
      plan: plan,
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
      |> Multi.insert(:membership, fn %{account: account, user: user} ->
        %AccountMembership{}
        |> AccountMembership.changeset(%{
          account_id: account.id,
          user_id: user.id,
          role: :owner,
          status: :active,
          joined_at: DateTime.utc_now()
        })
      end)

    case Repo.transaction(transaction) do
      {:ok, %{account: account, user: user, membership: membership}} ->
        {:ok, %{account: account, user: user, membership: membership}}

      {:error, step, reason, _changes} ->
        Logger.error(
          "registration transaction failed at step=#{inspect(step)} reason=#{inspect(reason)}"
        )

        {:error, :unable_to_issue_identity}
    end
  end

  defp user_by_email(email) when is_binary(email),
    do: Repo.get_by(PersistenceUser, email: email)

  # Look up the first :active AccountMembership for a User, SCOPED to the
  # Account being authenticated into. Used by authenticate_with_password/1
  # when the MEAL_PLANNER_TENANCY_V2 flag is on, so the PR 3 auth_controller
  # layer has the membership row it needs to mint an `access_v2` JWT.
  # Returns `nil` when the User has no membership on this Account (the
  # controller should fall back to the synthesized `current_membership`
  # path in that case).
  #
  # MUST filter by account_id: a multi-familia User can have :active
  # memberships on 2+ different Accounts. Without this filter, the
  # returned membership could belong to a different Account than the
  # `account` returned alongside it by authenticate_with_password/1 —
  # a tenancy-isolation bug (PR 2b post-review fix pass item 2).
  defp first_active_membership_for(%PersistenceUser{id: user_id}, %PersistenceAccount{
         id: account_id
       }) do
    query =
      from(m in AccountMembership,
        where: m.user_id == ^user_id and m.account_id == ^account_id and m.status == :active,
        order_by: [asc: m.inserted_at],
        limit: 1
      )

    Repo.one(query)
  end

  defp first_active_membership_for(_, _), do: nil

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

  defp upsert_account(db_account_id, plan, params) do
    with {:ok, subscription_plan_id} <- Subscriptions.ensure_default_plan_id(plan) do
      attrs = %{
        name: Map.get(params, "name", "MyFood User"),
        plan: plan,
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

  defp plan_from(account) when is_map(account) do
    case Map.get(account, :plan) do
      nil -> :individual
      plan when is_atom(plan) -> plan
      plan when is_binary(plan) -> String.to_existing_atom(plan)
    end
  end

  defp legacy_account_type_from_plan(:individual), do: "individual"
  defp legacy_account_type_from_plan(_), do: "group"

  defp max_users_for_plan(:individual), do: 1
  defp max_users_for_plan(:family_4), do: 4
  defp max_users_for_plan(:family_6), do: 6
  defp max_users_for_plan(:trial), do: 6
  defp max_users_for_plan(_), do: 1

  defp subscription_tier_from(entity) do
    Map.get(entity, :subscription_tier, :free)
  end
end
