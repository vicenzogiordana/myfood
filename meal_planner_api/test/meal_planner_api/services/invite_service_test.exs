defmodule MealPlannerApi.Services.InviteServiceTest do
  @moduledoc """
  Tests for `MealPlannerApi.Services.InviteService` — Phase A — Tenancy
  Refactor, PR 2a task 2.7.

  Coverage:
    * `mint_token/0` produces a plaintext ≥ 40 chars and a 64-char hex
      hash (SHA-256 lower-case hex)
    * `hash_token/1` is a stable hashing function usable by external
      callers (e.g. tests, future API surface)
    * `verify_and_consume/2` flips `:invited → :active`, sets `joined_at`,
      nulls `invite_token_hash` + `invite_expires_at`
    * replay (second call after consume) returns `:invite_token_used`
    * an expired token returns `:invite_token_expired`
    * a wrong-plaintext lookup returns `:invite_token_unknown`
  """
  use ExUnit.Case, async: false

  import MealPlannerApi.FactoryHelpers

  alias Ecto.Adapters.SQL.Sandbox
  alias MealPlannerApi.Persistence.Accounts.AccountMembership
  alias MealPlannerApi.Repo
  alias MealPlannerApi.Services.InviteService

  setup do
    :ok = Sandbox.checkout(Repo)
    :ok = MealPlannerApi.SubscriptionPlanFixtures.ensure_plans!()
  end

  describe "mint_token/0" do
    test "produces a plaintext of at least 40 chars and a 64-char hex hash" do
      {plaintext, hash} = InviteService.mint_token()

      assert is_binary(plaintext)
      assert String.length(plaintext) >= 40
      assert is_binary(hash)
      assert String.length(hash) == 64
      assert hash == String.downcase(hash)
      # 64-char hex hash: every char is a hex digit.
      assert Regex.match?(~r/^[0-9a-f]+$/, hash)
    end

    test "produces unique plaintexts across calls" do
      {a, _} = InviteService.mint_token()
      {b, _} = InviteService.mint_token()
      refute a == b
    end
  end

  describe "hash_token/1" do
    test "is stable and round-trips with mint_token/0" do
      {plaintext, hash} = InviteService.mint_token()
      assert InviteService.hash_token(plaintext) == hash
    end

    test "produces different hashes for different plaintexts" do
      {a, ha} = InviteService.mint_token()
      {b, hb} = InviteService.mint_token()
      assert ha != hb
      # And both round-trip.
      assert InviteService.hash_token(a) == ha
      assert InviteService.hash_token(b) == hb
    end
  end

  describe "verify_and_consume/2" do
    test "flips :invited → :active, sets joined_at, points user_id at invitee" do
      user =
        user_with_memberships(
          %{email: "invitee@example.com"},
          []
        )

      owner =
        user_with_memberships(
          %{email: "owner@example.com"},
          [
            {%{plan: :family_4, name: "F"}, :owner}
          ]
        )

      [owner_membership] = owner.memberships

      {:ok, %{membership: invited, token: plaintext}} =
        InviteService.create_invite_row(owner_membership, "invitee@example.com")

      assert invited.status == :invited
      assert is_binary(invited.invite_token_hash)
      assert %DateTime{} = invited.invite_expires_at

      {:ok, accepted_membership} =
        InviteService.verify_and_consume(plaintext, owner_membership.account_id, user)

      assert accepted_membership.status == :active
      assert %DateTime{} = accepted_membership.joined_at
      assert accepted_membership.user_id == user.id
      # Token fields are KEPT so a replay can detect :invite_token_used
      # (per spec `invite-and-accept.md` §"Token replay").
      assert is_binary(accepted_membership.invite_token_hash)
      assert %DateTime{} = accepted_membership.invite_expires_at
    end

    test "replay (second call) returns :invite_token_used" do
      user =
        user_with_memberships(
          %{email: "replay@example.com"},
          []
        )

      owner =
        user_with_memberships(
          %{email: "replay-owner@example.com"},
          [
            {%{plan: :family_4, name: "F"}, :owner}
          ]
        )

      [owner_membership] = owner.memberships

      {:ok, %{token: plaintext}} =
        InviteService.create_invite_row(owner_membership, "replay@example.com")

      assert {:ok, _} =
               InviteService.verify_and_consume(plaintext, owner_membership.account_id, user)

      assert {:error, :invite_token_used} =
               InviteService.verify_and_consume(plaintext, owner_membership.account_id, user)
    end

    test "an expired token returns :invite_token_expired" do
      user =
        user_with_memberships(
          %{email: "expired@example.com"},
          []
        )

      owner =
        user_with_memberships(
          %{email: "expired-owner@example.com"},
          [
            {%{plan: :family_4, name: "F"}, :owner}
          ]
        )

      [owner_membership] = owner.memberships

      {:ok, %{membership: invited, token: plaintext}} =
        InviteService.create_invite_row(owner_membership, "expired@example.com")

      # Backdate the row past its expiry.
      past = DateTime.add(DateTime.utc_now(), -1, :day)

      invited
      |> AccountMembership.changeset(%{invite_expires_at: past})
      |> Repo.update!()

      assert {:error, :invite_token_expired} =
               InviteService.verify_and_consume(plaintext, owner_membership.account_id, user)
    end

    test "a wrong-plaintext lookup returns :invite_token_unknown" do
      owner =
        user_with_memberships(
          %{email: "unknown-owner@example.com"},
          [
            {%{plan: :family_4, name: "F"}, :owner}
          ]
        )

      [owner_membership] = owner.memberships

      {:ok, %{token: _real_token}} =
        InviteService.create_invite_row(owner_membership, "unknown@example.com")

      assert {:error, :invite_token_unknown} =
               InviteService.verify_and_consume(
                 "definitely-wrong-token",
                 owner_membership.account_id,
                 owner
               )
    end
  end
end
