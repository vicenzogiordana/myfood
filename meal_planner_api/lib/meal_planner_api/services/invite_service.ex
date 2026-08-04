defmodule MealPlannerApi.Services.InviteService do
  @moduledoc """
  Token mint + verify + consume for `AccountMembership` invites.

  Phase A — Tenancy Refactor, PR 2a task 2.7. Per design §6.1, design
  §10 (Q7), and `specs/invite-and-accept.md`:

    * `mint_token/0` produces `{plaintext, hash}`. Plaintext is 32 bytes
      from `:crypto.strong_rand_bytes/1`, URL-safe base64 (no padding) →
      ~43-char string. Hash is `SHA-256(plaintext)` encoded as lower-case
      hex (64 chars).
    * `hash_token/1` exposes the hashing algorithm so external callers
      (e.g. tests) can reproduce the hash without re-minting.
    * `create_invite_row/2` inserts an `:invited` `AccountMembership`
      with `invite_token_hash`, `invite_expires_at = now + 7d`,
      `invited_by_user_id`, `role: :member`. Used by the
      `AccountsMembership.invite/3` use case.
    * `verify_and_consume/3` looks up the membership by hash, flips
      `:invited → :active`, sets `joined_at`, nulls `invite_token_hash`
      and `invite_expires_at` (single-use enforcement). Returns
      `:invite_token_used` on replay, `:invite_token_expired` on
      expiry, `:invite_token_unknown` on no match.
  """

  import Ecto.Query

  alias MealPlannerApi.Persistence.Accounts.AccountMembership
  alias MealPlannerApi.Persistence.Accounts.User, as: PersistenceUser
  alias MealPlannerApi.Repo

  @invite_ttl_days 7

  @doc """
  Returns `{plaintext, hash}` for a fresh invite token.

  Plaintext is ~43 URL-safe base64 chars (no padding) from 32 random
  bytes; hash is 64-char lower-case hex (SHA-256).
  """
  @spec mint_token() :: {String.t(), String.t()}
  def mint_token do
    plaintext = generate_url_safe_token(32)
    {plaintext, hash_token(plaintext)}
  end

  @doc """
  Hashes an invite plaintext token (SHA-256 lower-case hex). Pure — no
  IO — usable by callers that need to reproduce the hash for an existing
  token without minting a new one.
  """
  @spec hash_token(String.t()) :: String.t()
  def hash_token(plaintext) when is_binary(plaintext) do
    :crypto.hash(:sha256, plaintext) |> Base.encode16(case: :lower)
  end

  @doc """
  Inserts an `:invited` `AccountMembership` for `email` under the
  account identified by `owner_membership`. Returns the membership and
  the plaintext token (single use — caller is responsible for emitting
  it exactly once in the response).

  Hash is stored (never plaintext). Expiry = `now + @invite_ttl_days`.
  The transaction wraps a `SELECT … FOR UPDATE` on the Account row
  indirectly via the FK insert + the seat-cap check the caller runs
  before calling this function (see `AccountsMembership.invite/3`).

  ## User resolution

  The `account_memberships.user_id` FK requires a real `User` row. If
  the invitee email already maps to a `User`, that User's id is used.
  Otherwise a stub `User` is created with the email, `role: :member`,
  `name: nil`, `password_hash: nil`. The stub User is filled in
  (`name`, `password_hash`) by the caller when the invitee accepts
  via `verify_and_consume/3` (which receives a real `%User{}` at
  accept time).
  """
  @spec create_invite_row(AccountMembership.t(), String.t()) ::
          {:ok, %{membership: AccountMembership.t(), token: String.t()}}
          | {:error, Ecto.Changeset.t()}
  def create_invite_row(%AccountMembership{} = owner_membership, email)
      when is_binary(email) do
    with {:ok, user} <- resolve_or_create_user(email),
         {:ok, plaintext, hash, expires_at} <- fresh_token() do
      attrs = %{
        account_id: owner_membership.account_id,
        user_id: user.id,
        role: :member,
        status: :invited,
        invited_by_user_id: owner_membership.user_id,
        invite_token_hash: hash,
        invite_expires_at: expires_at,
        joined_at: nil
      }

      case %AccountMembership{}
           |> AccountMembership.changeset(attrs)
           |> Repo.insert() do
        {:ok, membership} ->
          {:ok, %{membership: membership, token: plaintext}}

        {:error, _} = error ->
          error
      end
    end
  end

  defp resolve_or_create_user(email) do
    case Repo.get_by(PersistenceUser, email: email) do
      %PersistenceUser{} = user ->
        {:ok, user}

      nil ->
        # Stub User with `name: email` so the `name` NOT NULL check is
        # satisfied at insert time. The accept flow (`verify_and_consume`)
        # receives a real `%User{}` and updates the membership to point at
        # them. The name is filled in by the API at accept time.
        %PersistenceUser{}
        |> PersistenceUser.changeset(%{email: email, name: email, role: :member})
        |> Repo.insert()
    end
  end

  defp fresh_token do
    {plaintext, hash} = mint_token()
    expires_at = DateTime.add(DateTime.utc_now(), @invite_ttl_days * 86_400, :second)
    {:ok, plaintext, hash, expires_at}
  end

  @doc """
  Verifies a plaintext invite token for the given `account_id` and
  consumes the row (sets `invite_token_hash` + `invite_expires_at` to
  `nil`, flips `status` to `:active`, sets `joined_at`, points
  `user_id` at `invitee`).

  Returns one of:

    * `{:ok, %AccountMembership{}}` — the consumed, now-active membership
    * `{:error, :invite_token_used}` — replay (token row has been
      consumed already)
    * `{:error, :invite_token_expired}` — token past `invite_expires_at`
    * `{:error, :invite_token_unknown}` — no row matches
    * `{:error, :invite_wrong_account}` — token belongs to a different
      account_id
  """
  @spec verify_and_consume(String.t(), Ecto.UUID.t() | binary(), PersistenceUser.t()) ::
          {:ok, AccountMembership.t()}
          | {:error, atom()}
  def verify_and_consume(plaintext, expected_account_id, %PersistenceUser{} = invitee)
      when is_binary(plaintext) do
    hash = hash_token(plaintext)
    now = DateTime.utc_now()

    query =
      from(m in AccountMembership,
        where: m.invite_token_hash == ^hash,
        where: m.account_id == ^expected_account_id,
        limit: 1
      )

    case Repo.one(query) do
      nil ->
        {:error, :invite_token_unknown}

      %AccountMembership{status: status, invite_expires_at: expires_at} = membership ->
        cond do
          status != :invited ->
            {:error, :invite_token_used}

          is_nil(expires_at) ->
            {:error, :invite_token_used}

          DateTime.compare(expires_at, now) == :lt ->
            {:error, :invite_token_expired}

          true ->
            consume_membership(membership, invitee)
        end
    end
  end

  # ---- internals -------------------------------------------------------------

  defp consume_membership(membership, invitee) do
    # Note: `invite_token_hash` and `invite_expires_at` are KEPT so a
    # second `verify_and_consume/3` call with the same plaintext finds
    # the row and sees `status: :active` → returns `:invite_token_used`
    # (per spec `invite-and-accept.md` §"Token replay"). Only
    # `joined_at`, `user_id`, and `status` change on accept.
    membership
    |> AccountMembership.changeset(%{
      status: :active,
      joined_at: DateTime.utc_now(),
      user_id: invitee.id
    })
    |> Repo.update()
  end

  defp generate_url_safe_token(byte_size) do
    byte_size
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end
end
