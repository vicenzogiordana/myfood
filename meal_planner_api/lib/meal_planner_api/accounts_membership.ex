defmodule MealPlannerApi.AccountsMembership do
  @moduledoc """
  Application-layer use cases for multi-familia tenancy.

  Phase A — Tenancy Refactor (PR 2a, tasks 2.1–2.8). This module owns the
  invitation lifecycle, seat-cap enforcement, roster listing, leave/switch
  flows, and the `access_v2` JWT claim builder. Persistence queries live in
  `MealPlannerApi.Persistence.Accounts.*` and `MealPlannerApi.Repo` —
  schemas are dumb data per Clean Architecture.

  See `specs/account-membership.md`, `invite-and-accept.md`,
  `multi-familia-switch-account.md`, and `guardian-jwt-claims.md`.
  """

  require Logger

  alias MealPlannerApi.Accounts
  alias MealPlannerApi.Persistence.Accounts.Account
  alias MealPlannerApi.Persistence.Accounts.AccountMembership
  alias MealPlannerApi.Persistence.Accounts.User, as: PersistenceUser
  alias MealPlannerApi.Repo
  alias MealPlannerApi.Services.InviteService

  import Ecto.Query

  @plan_capacities %{individual: 1, family_4: 4, family_6: 6, trial: 6}

  @doc """
  Builds the `access_v2` JWT claim map for the given user + membership
  pair. The result matches design §3.2 exactly (Guardian adds `iat` and
  `exp` at sign time — those are NOT application claims).

  ## Examples

      iex> claims = AccountsMembership.claims_for(user, membership)
      iex> claims["typ"]
      "access_v2"
  """
  @spec claims_for(PersistenceUser.t(), AccountMembership.t()) :: map()
  def claims_for(%PersistenceUser{} = user, %AccountMembership{} = membership) do
    plan = membership_plan(membership)

    %{
      "typ" => "access_v2",
      "membership_id" => to_string(membership.id),
      "account_id" => to_string(membership.account_id),
      "role" => Atom.to_string(membership.role),
      "plan" => Atom.to_string(plan),
      "status" => Atom.to_string(membership.status),
      "email" => user.email,
      "name" => user.name
    }
  end

  @doc """
  Returns the seat usage for an Account:

      %{active: N, invited: M, capacity: C}

  where `active` is the count of `:active` memberships, `invited` is the
  count of `:invited` memberships, and `capacity` is the plan's seat cap
  (1 for `:individual`, 4 for `:family_4`, 6 for `:family_6` and `:trial`).

  Per `specs/account-membership.md` §"Seat cap per Account.plan" the cap
  applies to `:active + :invited` rows.
  """
  @spec seat_usage(Account.t()) :: %{
          active: non_neg_integer(),
          invited: non_neg_integer(),
          capacity: pos_integer()
        }
  def seat_usage(%Account{plan: plan} = account) do
    query =
      from(m in AccountMembership,
        where: m.account_id == ^account.id,
        where: m.status in [:active, :invited],
        group_by: m.status,
        select: {m.status, count(m.id)}
      )

    counts =
      case Repo.all(query) do
        rows when is_list(rows) -> Map.new(rows)
        _ -> %{}
      end

    %{
      active: Map.get(counts, :active, 0),
      invited: Map.get(counts, :invited, 0),
      capacity: Map.fetch!(@plan_capacities, plan)
    }
  end

  @doc """
  Enforces the seat cap for an Account. Returns `:ok` when
  `active + invited + count_to_add` is at or below capacity, otherwise
  `{:error, :seat_cap_reached}`.

  Called inside the invite transaction (design §6.1) under
  `SELECT … FOR UPDATE` on the Account row to prevent the seat-cap race
  (proposal §"Risks").
  """
  @spec enforce_seat_cap(Account.t(), pos_integer()) ::
          :ok | {:error, :seat_cap_reached}
  def enforce_seat_cap(account, count_to_add \\ 1)
      when is_integer(count_to_add) and count_to_add >= 1 do
    %{active: active, invited: invited, capacity: capacity} = seat_usage(account)

    if active + invited + count_to_add > capacity do
      {:error, :seat_cap_reached}
    else
      :ok
    end
  end

  @doc """
  Invites a new email to an Account. Owner-only. Wraps
  `InviteService.create_invite_row/2` and `enforce_seat_cap/2` so the
  seat cap is checked atomically with the row insert.

  Refuses with:
    * `:not_owner` — `actor.role != :owner`
    * `:seat_cap_reached` — Account has reached the plan's seat cap
    * `:already_invited` — an `:invited` row already exists for the email
    * `:already_a_member` — an `:active` row already exists for the email

  On success returns `{:ok, %{token, expires_at, membership_id, email}}`
  where `token` is the plaintext (returned exactly once — caller is
  responsible for never logging or persisting it).
  """
  @spec invite(Account.t(), AccountMembership.t(), String.t()) ::
          {:ok,
           %{
             token: String.t(),
             expires_at: DateTime.t(),
             membership_id: String.t(),
             email: String.t()
           }}
          | {:error, atom()}
  def invite(%Account{} = account, %AccountMembership{role: role} = actor, email)
      when role == :owner and is_binary(email) do
    case Repo.transaction(fn ->
           with :ok <- lock_account_for_invite(account),
                :ok <- enforce_seat_cap(account, 1),
                :ok <- check_existing_membership(account, email),
                {:ok, %{membership: m, token: token}} <-
                  InviteService.create_invite_row(actor, email) do
             {:ok,
              %{
                token: token,
                expires_at: m.invite_expires_at,
                membership_id: to_string(m.id),
                email: email
              }}
           else
             {:error, _} = err -> err
           end
         end) do
      {:ok, {:ok, result}} -> {:ok, result}
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, _} -> {:error, :unable_to_invite}
    end
  end

  def invite(_account, %AccountMembership{}, _email), do: {:error, :not_owner}

  @doc """
  Resolves the `current_membership` from a JWT claim map. Mirrors the
  `LoadCurrentMembership` plug logic in `meal_planner_api_web/plugs/`
  (PR 1 task 1.10) so the application layer has a single source of
  truth for membership resolution — useful for tests, channels, and
  background jobs that need to bypass the conn pipeline.

  Per design §10 (Q1), when the JWT is `access_v1` (legacy) the
  function loads the real, `:active` `AccountMembership` row for
  `(user.id, claims["account_id"])`.

  Post-PR-3b review — BLOCKER fix (legacy membership synthesis): this
  used to fabricate an in-memory `%AccountMembership{status: :active}`
  struct straight from the claim, with `__synthesized__: true` and NO
  database lookup at all. `remove_member/3` and `leave/2` hard-delete
  the real row without ever clearing `user.account_id`, and legacy
  tokens carry a 4-week TTL with no server-side revocation — so a
  removed member's stale token retained full access for weeks. The
  function now REQUIRES a real, `:active` row; if none exists it
  returns `nil`, exactly like the `access_v2` no-membership case.

  Returns `nil` if `user` is `nil`, the membership can't be resolved,
  or the `typ` claim is unknown.
  """
  @spec current_membership(PersistenceUser.t() | nil, map()) :: AccountMembership.t() | nil
  def current_membership(nil, _claims), do: nil

  def current_membership(%PersistenceUser{} = user, claims) when is_map(claims) do
    case Map.get(claims, "typ", "access") do
      "access_v2" -> load_v2_membership(claims)
      "access" -> load_real_legacy_membership(user, claims)
      _ -> nil
    end
  end

  defp load_v2_membership(claims) do
    case Map.get(claims, "membership_id") do
      nil -> nil
      "" -> nil
      membership_id -> fetch_membership_by_id(membership_id)
    end
  end

  defp fetch_membership_by_id(membership_id) do
    case Ecto.UUID.cast(membership_id) do
      {:ok, uuid} ->
        case Repo.get(AccountMembership, uuid) do
          %AccountMembership{} = m -> m
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp load_real_legacy_membership(%PersistenceUser{} = user, claims) do
    case Map.get(claims, "account_id") do
      nil ->
        nil

      "" ->
        nil

      account_id ->
        case Ecto.UUID.cast(account_id) do
          {:ok, uuid} ->
            case Repo.get_by(AccountMembership,
                   user_id: user.id,
                   account_id: uuid,
                   status: :active
                 ) do
              nil ->
                Logger.warning(
                  "legacy access token denied: no active membership found user_id=#{user.id} account_id=#{uuid}"
                )

                nil

              %AccountMembership{} = membership ->
                membership
            end

          _ ->
            nil
        end
    end
  end

  @doc """
  Accepts an invite token. Two entry points:

    * `accept_invite(plaintext, %User{} = user)` — existing User. Flips
      the membership `:invited → :active`, sets `joined_at`, points
      `user_id` at the User. Returns the auth payload ready for the
      API layer to mint an `access_v2` JWT.

    * `accept_invite(plaintext, %{name: ..., password_hash: ...})` —
      new User. The `InviteService.create_invite_row/2` created a stub
      `User` row at invite time; this function fills it in with the
      real `name` and `password_hash`, then flips the membership.

  Errors: `:invite_token_used`, `:invite_token_expired`,
  `:invite_token_unknown`.

  The returned `claims` map matches design §3.2 — `AccountsMembership.
  claims_for/2` (task 2.1) is the single source of truth for the
  `access_v2` shape.
  """
  @spec accept_invite(String.t(), PersistenceUser.t() | map()) ::
          {:ok,
           %{
             user: PersistenceUser.t(),
             account: Account.t(),
             membership: AccountMembership.t(),
             claims: map()
           }}
          | {:error, atom()}
  def accept_invite(plaintext, %PersistenceUser{} = invitee) when is_binary(plaintext) do
    accept_invite_with_lookup(plaintext, fn _existing ->
      {:ok, invitee}
    end)
  end

  def accept_invite(plaintext, %{name: name, password_hash: password_hash})
      when is_binary(plaintext) and is_binary(name) and is_binary(password_hash) do
    accept_invite_with_lookup(plaintext, fn %PersistenceUser{id: user_id} = stub ->
      case stub
           |> PersistenceUser.changeset(%{name: name, password_hash: password_hash})
           |> Repo.update() do
        {:ok, %PersistenceUser{id: ^user_id} = updated} -> {:ok, updated}
        {:error, _} = err -> err
      end
    end)
  end

  def accept_invite(_plaintext, _args), do: {:error, :invalid_invitee}

  @doc """
  Multi-familia switch: re-issue the access_v2 claim set scoped to a
  different `:active` membership that the User already holds. Returns
  the auth payload ready for the controller to mint a fresh JWT.

  Refuses:

    * `:membership_not_found` — id doesn't resolve to any row
    * `:not_your_membership` — the membership belongs to a different User
    * `:membership_not_active` — the membership is `:invited`,
      `:suspended`, or otherwise non-active

  Per `specs/multi-familia-switch-account.md` this is the canonical
  "switch account" flow.
  """
  @spec switch_account(PersistenceUser.t(), Ecto.UUID.t() | binary()) ::
          {:ok,
           %{
             user: PersistenceUser.t(),
             account: Account.t(),
             membership: AccountMembership.t(),
             claims: map()
           }}
          | {:error, :membership_not_found | :not_your_membership | :membership_not_active}
  def switch_account(%PersistenceUser{id: user_id}, target_membership_id)
      when is_binary(target_membership_id) do
    with {:ok, uuid} <- cast_uuid(target_membership_id),
         {:ok, membership} <- load_active_membership(uuid),
         :ok <- assert_owner(user_id, membership),
         {:ok, account} <- load_account(membership.account_id) do
      membership = Repo.preload(membership, :account)
      # Refetch the User so we get the canonical email/name (not the
      # one the caller passed in — switch_account is security-sensitive
      # and should not trust caller-supplied identity fields).
      fresh_user = Repo.get!(PersistenceUser, user_id)

      {:ok,
       %{
         user: fresh_user,
         account: account,
         membership: membership,
         claims: build_response_claims(fresh_user, account, membership)
       }}
    end
  end

  def switch_account(_user, _id), do: {:error, :membership_not_found}

  # Post-review fix pass, item 2: `switch_account/2` and `accept_invite/2`
  # used to call `claims_for/2` directly, unconditionally minting
  # `access_v2` regardless of `MEAL_PLANNER_TENANCY_V2` — unlike
  # `auth_controller.ex`'s `password/2`, which gates issuance through the
  # same flag (see its private `issuance_typ/1`). This made the flag not a
  # real killswitch for these two flows. Mirrors `auth_controller.ex`'s
  # `tenancy_v2_only?/0` check exactly (same config key).
  defp build_response_claims(user, account, membership) do
    if tenancy_v2_only?() do
      claims_for(user, membership)
    else
      Accounts.claims_for(user, account)
    end
  end

  defp tenancy_v2_only? do
    Application.get_env(:meal_planner_api, :tenancy_v2_only, false)
  end

  defp load_active_membership(uuid) do
    case Repo.get(AccountMembership, uuid) do
      nil ->
        {:error, :membership_not_found}

      %AccountMembership{status: status} = _m when status != :active ->
        {:error, :membership_not_active}

      %AccountMembership{} = m ->
        {:ok, m}
    end
  end

  defp assert_owner(user_id, %AccountMembership{user_id: owner_id}) do
    if user_id == owner_id, do: :ok, else: {:error, :not_your_membership}
  end

  defp cast_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      _ -> {:error, :membership_not_found}
    end
  end

  defp cast_uuid(_), do: {:error, :membership_not_found}

  defp accept_invite_with_lookup(plaintext, resolve_user) when is_binary(plaintext) do
    hash = InviteService.hash_token(plaintext)

    query =
      from(m in AccountMembership,
        where: m.invite_token_hash == ^hash,
        where: m.status == :invited,
        limit: 1
      )

    case Repo.one(query) do
      nil ->
        # Could be :invite_token_used (replay) or :invite_token_unknown
        # (wrong plaintext) — distinguish by looking up by hash without
        # the :invited filter.
        if Repo.exists?(from(m in AccountMembership, where: m.invite_token_hash == ^hash)) do
          {:error, :invite_token_used}
        else
          {:error, :invite_token_unknown}
        end

      %AccountMembership{} = membership ->
        now = DateTime.utc_now()

        cond do
          is_nil(membership.invite_expires_at) ->
            {:error, :invite_token_used}

          DateTime.compare(membership.invite_expires_at, now) == :lt ->
            {:error, :invite_token_expired}

          true ->
            with {:ok, stub_user} <- fetch_membership_user(membership),
                 {:ok, invitee} <- resolve_user.(stub_user),
                 {:ok, consumed} <-
                   Repo.update(
                     AccountMembership.changeset(membership, %{
                       status: :active,
                       joined_at: DateTime.utc_now(),
                       user_id: invitee.id
                     })
                   ),
                 {:ok, account} <- load_account(consumed.account_id) do
              consumed = Repo.preload(consumed, :account)

              {:ok,
               %{
                 user: invitee,
                 account: account,
                 membership: consumed,
                 claims: build_response_claims(invitee, account, consumed)
               }}
            else
              {:error, reason} -> {:error, reason}
            end
        end
    end
  end

  # PR 3a task 3.4 fix: `resolve_user.()` must receive the actual stub
  # `%PersistenceUser{}` row created by
  # `InviteService.create_invite_row/2` (looked up by
  # `membership.user_id`), not a placeholder atom — the "new User"
  # arity's closure pattern-matches `%PersistenceUser{}` and always
  # raised `FunctionClauseError` before this fix.
  defp fetch_membership_user(%AccountMembership{user_id: user_id}) do
    case Repo.get(PersistenceUser, user_id) do
      %PersistenceUser{} = user -> {:ok, user}
      nil -> {:error, :invite_token_unknown}
    end
  end

  @doc """
  Loads an `Account` by its (string) id. Returns `{:error,
  :account_not_found}` for a malformed id or a missing row.

  Public (post-review fix pass item 5) so
  `MealPlannerApiWeb.Controllers.AccountScopeHelpers.load_account/1` can
  delegate here instead of duplicating the same
  `Ecto.UUID.cast/1` → `Repo.get/2` → error-tuple shape.
  """
  @spec load_account(String.t()) :: {:ok, Account.t()} | {:error, :account_not_found}
  def load_account(account_id) do
    case Ecto.UUID.cast(account_id) do
      {:ok, uuid} ->
        case Repo.get(Account, uuid) do
          %Account{} = account -> {:ok, account}
          nil -> {:error, :account_not_found}
        end

      _ ->
        {:error, :account_not_found}
    end
  end

  @doc """
  Lists the membership roster for an Account, ordered owner-first then
  by `joined_at ASC`. Preloads `:user` for the controller layer to
  render `email`, `name`, etc.

  Per `specs/invite-and-accept.md` §"Membership roster" the response
  MUST include `:active` and `:invited` rows; `:suspended` is excluded
  in practice (no API path mints a `:suspended` row in Phase A — that
  status is reserved for the future re-invitation flow).

  Owner-first is achieved by a `CASE` over the role enum (`:owner <
  :member` alphabetically is the opposite of what the spec wants).
  """
  @spec list_memberships(Account.t()) :: [AccountMembership.t()]
  def list_memberships(%Account{} = account) do
    query =
      from(m in AccountMembership,
        where: m.account_id == ^account.id,
        where: m.status in [:active, :invited],
        order_by: [
          asc: fragment("CASE WHEN ? = 'owner' THEN 0 ELSE 1 END", m.role),
          asc: m.joined_at,
          asc: m.inserted_at
        ],
        preload: [:user]
      )

    Repo.all(query)
  end

  @doc """
  Hard-deletes a `:member` membership. Owner-only. Refuses the owner
  with `:cannot_remove_owner` (decision 5.7). Refuses unknown
  `user_id` with `:membership_not_found`.

  The seat cap is checked by `invite/3` on the next re-invitation —
  per spec `account-membership.md` §"Seat cap per Account.plan",
  reactivation re-checks the cap.
  """
  @spec remove_member(Account.t(), Ecto.UUID.t() | binary(), AccountMembership.t()) ::
          :ok | {:error, :not_owner | :cannot_remove_owner | :membership_not_found}
  def remove_member(
        %Account{} = account,
        target_user_id,
        %AccountMembership{role: :owner} = actor
      )
      when is_binary(target_user_id) do
    if actor.user_id == target_user_id do
      {:error, :cannot_remove_owner}
    else
      case Repo.get_by(AccountMembership, account_id: account.id, user_id: target_user_id) do
        nil ->
          {:error, :membership_not_found}

        %AccountMembership{id: id} ->
          case Repo.delete_all(from(m in AccountMembership, where: m.id == ^id)) do
            {1, _} -> :ok
            _ -> {:error, :membership_not_found}
          end
      end
    end
  end

  def remove_member(_account, _target_user_id, _actor), do: {:error, :not_owner}

  @doc """
  Self-removal for a `:member`. Owners cannot leave — return
  `:cannot_leave_owned_account` (decision 5.7). Account transfer /
  dissolve flows are deferred to a follow-up change.

  Order of checks: first verify the actor has a row on THIS Account
  (else `:not_a_member`); then verify the role is `:member` (else
  `:cannot_leave_owned_account`). This ordering prevents a User who
  is the owner of a *different* Account from triggering
  `:cannot_leave_owned_account` against an Account they don't belong
  to — they should get `:not_a_member` instead.

  Looks the row up by `user_id` + `account_id`, NOT by `actor.id`.
  `actor` may be a **synthesized** legacy membership (`__synthesized__:
  true`, `id: nil` — see `LoadCurrentMembership.synthesize_v1_membership/2`)
  for `access_v1` token holders; `id: nil` never matches a real primary
  key, so an `id`-based lookup always returned `nil` for every legacy
  User, making this function permanently broken for them. The
  synthesized struct does carry the real `user_id`, which is what both
  real and synthesized memberships have in common.
  """
  @spec leave(Account.t(), AccountMembership.t()) ::
          :ok | {:error, :cannot_leave_owned_account | :not_a_member}
  def leave(%Account{} = account, %AccountMembership{} = actor) do
    case Repo.get_by(AccountMembership, user_id: actor.user_id, account_id: account.id) do
      nil ->
        {:error, :not_a_member}

      %AccountMembership{role: :owner} ->
        {:error, :cannot_leave_owned_account}

      %AccountMembership{role: :member, id: id} ->
        case Repo.delete_all(from(m in AccountMembership, where: m.id == ^id)) do
          {1, _} -> :ok
          _ -> {:error, :not_a_member}
        end
    end
  end

  # Per proposal §"Risks" (seat-cap race), we hold a row-level lock on
  # the Account during the seat-cap check + invite insert. The lock is
  # released when the transaction commits.
  defp lock_account_for_invite(%Account{id: account_id}) do
    case Ecto.UUID.cast(account_id) do
      {:ok, uuid} ->
        query =
          from(a in Account,
            where: a.id == ^uuid,
            lock: "FOR UPDATE"
          )

        case Repo.one(query) do
          %Account{} -> :ok
          _ -> {:error, :account_not_found}
        end

      _ ->
        {:error, :account_not_found}
    end
  end

  defp check_existing_membership(%Account{id: account_id}, email) do
    query =
      from(m in AccountMembership,
        join: u in PersistenceUser,
        on: u.id == m.user_id,
        where: m.account_id == ^account_id and u.email == ^email,
        where: m.status in [:invited, :active],
        limit: 1,
        select: m.status
      )

    case Repo.one(query) do
      nil -> :ok
      :invited -> {:error, :already_invited}
      :active -> {:error, :already_a_member}
    end
  end

  # Look up the Account.plan on the membership if `:account` is preloaded;
  # otherwise fetch it from the DB. Avoids an N+1 when callers already
  # preloaded, while still working for callers that did not.
  defp membership_plan(%AccountMembership{account: %Account{plan: plan}}),
    do: plan

  defp membership_plan(%AccountMembership{account_id: account_id}) do
    case Ecto.UUID.cast(account_id) do
      {:ok, uuid} ->
        case Repo.get(Account, uuid) do
          %Account{plan: plan} -> plan
          _ -> :individual
        end

      _ ->
        :individual
    end
  end
end
