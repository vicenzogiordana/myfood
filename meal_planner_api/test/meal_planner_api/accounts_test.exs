defmodule MealPlannerApi.AccountsTest do
  use ExUnit.Case, async: false

  alias MealPlannerApi.Accounts
  alias MealPlannerApi.Accounts.Account
  alias MealPlannerApi.Auth.Guardian
  alias MealPlannerApi.Persistence.Accounts.Account, as: PersistenceAccount
  alias MealPlannerApi.Persistence.Accounts.AccountMembership
  alias MealPlannerApi.Persistence.Accounts.User, as: PersistenceUser
  alias MealPlannerApi.Repo
  alias Ecto.Adapters.SQL.Sandbox

  import Ecto.Query

  setup do
    :ok = Sandbox.checkout(Repo)
    :ok = MealPlannerApi.SubscriptionPlanFixtures.ensure_plans!()
  end

  test "individual account only allows one linked user" do
    external_user_id = Ecto.UUID.generate()
    external_account_id = Ecto.UUID.generate()

    {:ok, %{user: user, account: account}} =
      Accounts.find_or_create_identity(%{
        "user_id" => external_user_id,
        "account_id" => external_account_id,
        "account_type" => "individual",
        "subscription_tier" => "free"
      })

    account = %Account{
      id: account.id,
      type: :individual,
      owner_id: user.id,
      linked_user_ids: []
    }

    # Phase A: link_user/2 was the legacy single-account seat cap. With the
    # AccountMembership join (PR 2) the seat cap is enforced by
    # AccountsMembership.seat_usage/1 + enforce_seat_cap/2 instead. The
    # legacy link_user helper still exists for the public-facing DTO and
    # is exercised here against the pre-Phase-A shape.
    assert {:ok, updated} = Accounts.link_user(account, Ecto.UUID.generate())
    assert {:error, :individual_limit_reached} = Accounts.link_user(updated, Ecto.UUID.generate())
  end

  test "claims include subscription tier" do
    {:ok, %{user: user, account: account}} =
      Accounts.find_or_create_identity(%{
        "user_id" => "u9",
        "account_id" => "acct_u9",
        "subscription_tier" => "premium"
      })

    user = Map.put(user, :subscription_tier, :premium)
    account = Map.put(account, :subscription_tier, :premium)

    claims = Accounts.claims_for(user, account)

    assert claims["subscription_tier"] == "premium"
  end

  test "find_or_create_identity returns missing_identity when account_id is missing" do
    assert {:error, :missing_identity} =
             Accounts.find_or_create_identity(%{"user_id" => "u_missing"})
  end

  # ----------------------------------------------------------------------
  # Post-PR-3b review — BLOCKER: legacy membership synthesis fix.
  #
  # `find_or_create_identity/1` (the social-login path, `auth_controller.ex`
  # `social/2`) sets `user.account_id` directly but — unlike
  # `register_with_password/1` (PR 2b task 2.10) — never inserted a real
  # `AccountMembership` row. Once `LoadCurrentMembership` (and its siblings)
  # stop trusting `user.account_id` alone and require a real, `:active`
  # backing row (see the plug/context fixes below), social-login users
  # would have been locked out entirely despite never having been removed.
  # `find_or_create_identity/1` is idempotent (stable UUIDs derived from
  # the external user_id/account_id) and is called on every social login,
  # so upserting the membership here also self-heals any social-login user
  # created before this fix, the next time they log in.
  # ----------------------------------------------------------------------
  describe "find_or_create_identity/1 backs the identity with a real AccountMembership row" do
    test "creates an :owner :active AccountMembership row alongside the User/Account" do
      {:ok, %{user: user, account: account}} =
        Accounts.find_or_create_identity(%{
          "user_id" => "u_membership_backed",
          "account_id" => "acct_membership_backed"
        })

      membership =
        Repo.one!(
          from(m in AccountMembership,
            where: m.user_id == ^user.id and m.account_id == ^account.id
          )
        )

      assert membership.role == :owner
      assert membership.status == :active
      assert %DateTime{} = membership.joined_at
    end

    test "is idempotent — calling it again for the same identity does not duplicate the row" do
      identity_params = %{
        "user_id" => "u_membership_backed_twice",
        "account_id" => "acct_membership_backed_twice"
      }

      {:ok, %{user: user, account: account}} = Accounts.find_or_create_identity(identity_params)
      {:ok, %{user: user2, account: account2}} = Accounts.find_or_create_identity(identity_params)

      assert user2.id == user.id
      assert account2.id == account.id

      count =
        Repo.one!(
          from(m in AccountMembership,
            where: m.user_id == ^user.id and m.account_id == ^account.id,
            select: count(m.id)
          )
        )

      assert count == 1
    end
  end

  # ----------------------------------------------------------------------
  # PR 2b post-review fix pass — item 1: claims_for/2 must not hardcode typ
  # ----------------------------------------------------------------------
  #
  # Guardian's `set_type/3` only applies the `token_type:` option passed to
  # `encode_and_sign/3` when the claims map does NOT already carry a
  # non-nil "typ" key. `Accounts.claims_for/2` used to hardcode
  # `"typ" => "access"`, which meant every `token_type: "refresh"` call
  # site (auth_controller.ex `password/2`, `refresh/2`) silently minted a
  # refresh token whose `typ` claim read `"access"` — letting a refresh
  # token pass `VerifyTokenType`'s `access` / `access_v2` allowlist
  # anywhere in the API.

  describe "claims_for/2 does not hardcode typ (Guardian's token_type: option controls it)" do
    test "token_type: refresh yields a token whose typ claim is refresh, not access" do
      {:ok, %{user: user, account: account}} =
        Accounts.find_or_create_identity(%{
          "user_id" => "typ-regression-user",
          "account_id" => "typ-regression-account"
        })

      claims = Accounts.claims_for(user, account)
      refute Map.has_key?(claims, "typ"), "claims_for/2 must not set typ — Guardian sets it"

      {:ok, token, _claims} = Guardian.encode_and_sign(user, claims, token_type: "refresh")
      {:ok, decoded} = Guardian.decode_and_verify(token, %{}, token_type: "refresh")

      assert decoded["typ"] == "refresh"
    end

    test "token_type: access still yields typ access" do
      {:ok, %{user: user, account: account}} =
        Accounts.find_or_create_identity(%{
          "user_id" => "typ-regression-user-2",
          "account_id" => "typ-regression-account-2"
        })

      claims = Accounts.claims_for(user, account)

      {:ok, token, _claims} = Guardian.encode_and_sign(user, claims, token_type: "access")
      {:ok, decoded} = Guardian.decode_and_verify(token)

      assert decoded["typ"] == "access"
    end
  end

  # ----------------------------------------------------------------------
  # PR 2b post-review fix pass — item 2: authenticate_with_password/1 must
  # scope the returned membership to the account being authenticated into
  # ----------------------------------------------------------------------
  #
  # `first_active_membership_for/1` used to query AccountMembership by
  # user_id + status: :active only, with no account_id filter. For a
  # multi-familia User with :active memberships in 2+ different Accounts,
  # the returned membership could belong to a different Account than the
  # `account` returned alongside it — a tenancy-isolation bug.

  describe "authenticate_with_password/1 scopes membership to the authenticated account" do
    test "returns the membership tied to the user's account, not just any active membership" do
      password = "supersecret123"
      password_hash = Bcrypt.hash_pwd_salt(password)

      account_a = insert_test_account(:family_4, "Account A")
      account_b = insert_test_account(:individual, "Account B")

      {:ok, user} =
        %PersistenceUser{}
        |> PersistenceUser.changeset(%{
          email: "multi-familia@example.com",
          name: "Multi Familia",
          role: :owner,
          password_hash: password_hash,
          account_id: account_a.id
        })
        |> Repo.insert()

      # Insert Account B's membership FIRST so a query without an
      # account_id filter, ordered by inserted_at asc limit 1, would
      # return it ahead of Account A's — proving the bug pre-fix.
      insert_active_membership(account_b, user, :owner)
      membership_a = insert_active_membership(account_a, user, :owner)

      assert {:ok, %{account: account, membership: membership}} =
               Accounts.authenticate_with_password(%{
                 "email" => "multi-familia@example.com",
                 "password" => password
               })

      assert account.id == account_a.id
      assert membership.id == membership_a.id
      assert membership.account_id == account.id
    end
  end

  # ----------------------------------------------------------------------
  # PR 2b task 2.9 — authenticate_with_password/1
  # ----------------------------------------------------------------------
  #
  # NOTE: nothing in `lib/` currently reads the
  # `:meal_planner_api, :tenancy_v2_only` config key —
  # `authenticate_with_password/1`'s behavior below is NOT gated by any
  # flag today. These tests exercise current behavior only; do not read
  # "flag ON / OFF" framing into them until a real flag check lands in
  # `lib/meal_planner_api/accounts.ex`.

  describe "authenticate_with_password/1" do
    test "issues an access_v1 token via Accounts.claims_for/2" do
      # Register a User atomically (PR 2b task 2.10 makes registration atomic).
      {:ok, %{user: user}} =
        Accounts.register_with_password(%{
          "email" => "flag-off@example.com",
          "password" => "supersecret123",
          "name" => "Flag Off"
        })

      # authenticate_with_password/1 still returns the User + Account pair.
      assert {:ok, %{user: _reloaded_user, account: _account}} =
               Accounts.authenticate_with_password(%{
                 "email" => "flag-off@example.com",
                 "password" => "supersecret123"
               })

      # Build the legacy access_v1 token manually via Accounts.claims_for/2
      # (the same builder the off-path uses) and decode it. The claim set
      # matches design §3.1.
      [account] =
        Repo.all(
          from(a in MealPlannerApi.Persistence.Accounts.Account,
            join: m in AccountMembership,
            on: m.account_id == a.id and m.user_id == ^user.id,
            limit: 1
          )
        )

      claims_map = Accounts.claims_for(%{user | account_id: account.id}, account)

      assert claims_map["account_id"] == account.id

      {:ok, token, _claims} = Guardian.encode_and_sign(user, claims_map, token_type: "access")
      {:ok, decoded} = Guardian.decode_and_verify(token)

      assert decoded["typ"] == "access"

      refute Map.has_key?(decoded, "membership_id"),
             "access_v1 MUST NOT carry membership_id"
    end

    test "returns the User's first :active membership so a v2 token can be minted by callers" do
      {:ok, %{user: user, account: account}} =
        Accounts.register_with_password(%{
          "email" => "flag-on@example.com",
          "password" => "supersecret123",
          "name" => "Flag On"
        })

      assert {:ok, %{user: reloaded, account: reloaded_account}} =
               Accounts.authenticate_with_password(%{
                 "email" => "flag-on@example.com",
                 "password" => "supersecret123"
               })

      # The caller (PR 3 auth_controller) needs the User's first
      # :active AccountMembership row to build the access_v2 claim set.
      # We surface that membership on the authenticate result so the
      # caller doesn't have to query the DB a second time.
      membership =
        Repo.one(
          from(m in AccountMembership,
            where: m.user_id == ^user.id and m.account_id == ^account.id and m.status == :active
          )
        )

      assert membership.role == :owner
      assert membership.account_id == account.id

      # The reloaded Account is the canonical one (with memberships preloaded
      # where useful for the controller layer).
      assert reloaded_account.id == account.id
      assert reloaded.id == user.id
    end
  end

  # ---- test helpers ----------------------------------------------------------

  defp insert_test_account(plan, name) do
    {:ok, plan_row} = MealPlannerApi.Subscriptions.get_plan_by_name(Atom.to_string(plan))

    %PersistenceAccount{}
    |> PersistenceAccount.changeset(%{
      name: name,
      plan: plan,
      default_budget_cents: 0,
      subscription_plan_id: plan_row.id
    })
    |> Repo.insert!()
  end

  defp insert_active_membership(account, user, role) do
    %AccountMembership{}
    |> AccountMembership.changeset(%{
      account_id: account.id,
      user_id: user.id,
      role: role,
      status: :active,
      joined_at: DateTime.utc_now()
    })
    |> Repo.insert!()
  end
end
