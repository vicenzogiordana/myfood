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
         {:ok, %{account: account, user: user}} <-
           upsert_identity_transaction(db_account_id, db_user_id, plan, params) do
      {:ok, %{user: user, account: account}}
    else
      {:error, :missing_identity} -> {:error, :missing_identity}
      _ -> {:error, :unable_to_issue_identity}
    end
  end

  # Post-review fix (CRITICAL item 3): the 3 upserts used to run as 3
  # independent Repo calls inside the `with` chain above. If :membership
  # failed AFTER :account/:user already committed, the function fell
  # through to {:error, :unable_to_issue_identity} with NO rollback,
  # leaving exactly the broken (account+user exist, no active
  # membership) state this whole fix pass exists to eliminate — reachable
  # via any transient write failure (FK violation, race, DB blip), not
  # just the original design gap. `upsert_account/3` and `upsert_user/3`
  # are "get-or-insert-or-update" patterns (not pure inserts), so
  # `Multi.run/3` is used for each step (runs arbitrary logic inside the
  # transaction, still rolls back on `{:error, _}`) rather than
  # restructuring them into pure `Multi.insert`/`Multi.update` calls.
  defp upsert_identity_transaction(db_account_id, db_user_id, plan, params) do
    transaction_result =
      db_account_id
      |> build_identity_multi(db_user_id, plan, params)
      |> Repo.transaction()

    case transaction_result do
      {:ok, %{account: account, user: user}} ->
        {:ok, %{account: account, user: user}}

      {:error, step, reason, _changes} ->
        log_transaction_failure(step, reason)

        {:error, :unable_to_issue_identity}
    end
  end

  # Post-second-review fix (CRITICAL item 2, test-quality): extracted out
  # of `upsert_identity_transaction/4` so the test suite can introspect
  # the REAL production `Ecto.Multi` (step names + order) that
  # `find_or_create_identity/1` runs, instead of a hand-rolled "shape
  # equivalence" copy. `@doc false` + public rather than `defp` — same
  # pattern as `AccountsMembership.load_account/1`'s post-review fix
  # (public so a caller/test can delegate here instead of duplicating).
  # This function only BUILDS the `Multi` (pure data, no DB access) — it
  # does not execute or commit anything itself.
  @doc false
  @spec build_identity_multi(String.t(), String.t(), atom(), map()) :: Multi.t()
  def build_identity_multi(db_account_id, db_user_id, plan, params) do
    Multi.new()
    # Post-second-review fix (CRITICAL item 1, continued): the Account
    # row lock (see `first_member_role/1` below) MUST be taken as the
    # very FIRST statement in this transaction, before `:user`'s insert.
    # `AccountMembership.changeset/2`'s `foreign_key_constraint(:account_id)`
    # (and `User`'s own FK to `account_id`) make Postgres implicitly
    # take a weak `FOR KEY SHARE` lock on the referenced Account row
    # whenever `:user` or `:membership` inserts a row pointing at it. If
    # the exclusive `FOR UPDATE` lock were only taken later (inside
    # `:membership`), two concurrent transactions could each already be
    # holding the OTHER's needed `FOR KEY SHARE` (from their own `:user`
    # insert) by the time both try to upgrade to `FOR UPDATE` — a
    # textbook mutual lock-upgrade deadlock (Postgres error 40P01),
    # verified empirically while building this fix (see
    # apply-progress.md). Locking first avoids the upgrade entirely: a
    # second transaction blocks on `FOR KEY SHARE` (its `:user` step)
    # before it ever gets to request its own `FOR UPDATE`.
    |> Multi.run(:account_lock, fn _repo, _changes ->
      {:ok, lock_account_row(db_account_id)}
    end)
    |> Multi.run(:account, fn _repo, _changes -> upsert_account(db_account_id, plan, params) end)
    |> Multi.run(:user, fn _repo, _changes -> upsert_user(db_user_id, db_account_id, params) end)
    |> Multi.run(:membership, fn _repo, _changes ->
      upsert_membership(db_user_id, db_account_id)
    end)
  end

  # Post-second-review fix (WARNING item 3): `reason` can be an
  # `%Ecto.Changeset{}` (when :account or :user's upsert fails
  # validation) whose default `Inspect` implementation prints the full
  # `:changes` map — including PII (`email`, `name`) — into logs at
  # `:error` level. Log only the changeset's `:errors` (validation atoms
  # / messages, never the changed field values) for that case; fall back
  # to logging the reason's shape (not raw `inspect/1`) for anything
  # else, since arbitrary future failure reasons could also carry
  # caller-supplied data.
  defp log_transaction_failure(step, %Ecto.Changeset{errors: errors}) do
    Logger.error(
      "find_or_create_identity transaction failed at step=#{inspect(step)} changeset_errors=#{inspect(errors)}"
    )
  end

  defp log_transaction_failure(step, reason) when is_struct(reason) do
    Logger.error(
      "find_or_create_identity transaction failed at step=#{inspect(step)} reason_struct=#{inspect(reason.__struct__)}"
    )
  end

  defp log_transaction_failure(step, reason) when is_atom(reason) or is_binary(reason) do
    Logger.error(
      "find_or_create_identity transaction failed at step=#{inspect(step)} reason=#{inspect(reason)}"
    )
  end

  defp log_transaction_failure(step, reason) do
    kind = if is_tuple(reason), do: :tuple, else: :unstructured

    Logger.error(
      "find_or_create_identity transaction failed at step=#{inspect(step)} reason_kind=#{kind}"
    )
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
  @spec seat_usage(map()) :: %{
          active: non_neg_integer(),
          invited: non_neg_integer(),
          capacity: pos_integer()
        }
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

  # Post-PR-3b review — BLOCKER fix (legacy membership synthesis): this
  # social-login identity path used to create/update the User row with
  # `account_id` set, but NEVER inserted a real `AccountMembership` row —
  # unlike `register_with_password/1` (PR 2b task 2.10), which does so
  # atomically. `LoadCurrentMembership` and its siblings now REQUIRE a
  # real `:active` AccountMembership row before granting access via a
  # legacy `access` token (they no longer trust `user.account_id` alone —
  # see those modules' docs). Without this upsert, every social-login user
  # would be locked out of their own account. Idempotent: safe to call on
  # every login.
  defp upsert_membership(db_user_id, db_account_id) do
    case Repo.get_by(AccountMembership, user_id: db_user_id, account_id: db_account_id) do
      nil ->
        %AccountMembership{}
        |> AccountMembership.changeset(%{
          user_id: db_user_id,
          account_id: db_account_id,
          role: first_member_role(db_account_id),
          status: :active,
          joined_at: DateTime.utc_now()
        })
        |> Repo.insert()

      %AccountMembership{} = membership ->
        {:ok, membership}
    end
  end

  # Post-review fix (CRITICAL item 2): `db_account_id` is a stable UUID
  # derived purely from hashing the external `account_id` string, so two
  # DISTINCT external users authenticating against the same external
  # `account_id` (this app's own account-linking/shared-account model —
  # see `Account.linked_user_ids` / `link_user/2`) map to the same
  # internal Account row. The lookup key above is (user_id, account_id),
  # not "does this Account already have an owner" — so every distinct
  # user who links to an already-owned Account used to be inserted as a
  # NEW `:owner`, gaining full owner authority (`remove_member/3`,
  # `invite/3` both gate on `actor.role == :owner`) they should never
  # have. The first person to join an Account is its `:owner`; everyone
  # after that joins as a `:member` — mirrors the old (removed)
  # synthesized struct's `role: user.role || :member` default.
  # Post-second-review fix (CRITICAL item 1): this used to do an
  # UNLOCKED `Repo.exists?` check, then — in a separate step back in
  # `upsert_membership/2` — insert the new membership. Under Postgres's
  # default READ COMMITTED isolation, two concurrent transactions racing
  # to join the SAME Account (two distinct users, e.g. a pre-provisioned
  # family account whose members log in for the first time around the
  # same moment — see `upsert_account/3`'s doc: `db_account_id` is a
  # stable hash of the external `account_id`, so this Account already
  # exists with the SAME id for every racer) could both observe "no
  # existing membership" before either committed, both getting inserted
  # as `:owner`.
  #
  # Fix: `upsert_identity_transaction/4` now takes a `FOR UPDATE` row lock
  # on the Account row (see `lock_account_row/1`, same pattern as
  # `AccountsMembership.lock_account_for_invite/1`) as the FIRST statement
  # of the enclosing transaction — BEFORE this exists? check ever runs.
  # The lock is held until that transaction commits or rolls back: a
  # second concurrent transaction blocks on ITS OWN lock attempt until the
  # first fully commits, and then correctly observes the first membership
  # already exists.
  #
  # The lock is intentionally NOT (re-)acquired here, right before the
  # exists? check, even though that reads as the more "obvious" place for
  # it: `:user`'s insert (the Multi step immediately before this one) has
  # a `foreign_key_constraint(:account_id)`, which makes Postgres take an
  # implicit weak `FOR KEY SHARE` lock on this same Account row. Two
  # concurrent transactions each already holding the OTHER's needed `FOR
  # KEY SHARE` (from their own `:user` step) and only THEN both trying to
  # upgrade to `FOR UPDATE` here is a textbook mutual lock-upgrade
  # deadlock (Postgres error 40P01) — reproduced empirically while
  # building this fix (see apply-progress.md). Locking first, before
  # `:user` runs for anyone, avoids the upgrade entirely.
  defp first_member_role(db_account_id) do
    if Repo.exists?(from(m in AccountMembership, where: m.account_id == ^db_account_id)) do
      :member
    else
      :owner
    end
  end

  defp lock_account_row(db_account_id) do
    case Ecto.UUID.cast(db_account_id) do
      {:ok, uuid} ->
        from(a in PersistenceAccount, where: a.id == ^uuid, lock: "FOR UPDATE")
        |> Repo.one()

      _ ->
        nil
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
