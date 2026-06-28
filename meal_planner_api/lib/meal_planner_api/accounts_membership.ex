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
      from m in AccountMembership,
        where: m.account_id == ^account.id,
        where: m.status in [:active, :invited],
        group_by: m.status,
        select: {m.status, count(m.id)}

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
  def enforce_seat_cap(account, count_to_add \\ 1) when is_integer(count_to_add) and count_to_add >= 1 do
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
          {:ok, %{token: String.t(), expires_at: DateTime.t(), membership_id: String.t(), email: String.t()}}
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

  # Per proposal §"Risks" (seat-cap race), we hold a row-level lock on
  # the Account during the seat-cap check + invite insert. The lock is
  # released when the transaction commits.
  defp lock_account_for_invite(%Account{id: account_id}) do
    case Ecto.UUID.cast(account_id) do
      {:ok, uuid} ->
        query =
          from a in Account,
            where: a.id == ^uuid,
            lock: "FOR UPDATE"

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
      from m in AccountMembership,
        join: u in PersistenceUser,
        on: u.id == m.user_id,
        where: m.account_id == ^account_id and u.email == ^email,
        where: m.status in [:invited, :active],
        limit: 1,
        select: m.status

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
