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
  alias Ecto.Multi

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
  # Post-PR-3b re-review — CRITICAL item 2: upsert_membership/2 hardcoded
  # role: :owner (privilege escalation).
  #
  # `db_account_id` is a stable UUID derived purely from hashing the
  # external `account_id` string, so two DISTINCT external users
  # authenticating against the same external `account_id` (this app's
  # own account-linking/shared-account model) map to the same internal
  # Account row. `upsert_membership/2` used to always insert a NEW
  # membership with `role: :owner` — the lookup key is (user_id,
  # account_id), not "does this account already have an owner" — so
  # every distinct user who links to an already-owned account got
  # inserted as a NEW :owner, gaining full owner authority
  # (remove_member/3, invite/3 both gate on actor.role == :owner) they
  # should never have.
  # ----------------------------------------------------------------------
  describe "find_or_create_identity/1 only grants :owner to the FIRST member of an Account" do
    test "a second, distinct user linking to an already-owned account is inserted as :member, not :owner" do
      shared_external_account_id = "acct_shared_privilege_escalation"

      {:ok, %{user: first_user, account: account}} =
        Accounts.find_or_create_identity(%{
          "user_id" => "u_first_owner",
          "account_id" => shared_external_account_id
        })

      {:ok, %{user: second_user, account: second_account}} =
        Accounts.find_or_create_identity(%{
          "user_id" => "u_second_should_be_member",
          "account_id" => shared_external_account_id
        })

      # Same external account_id => same stable db_account_id.
      assert second_account.id == account.id
      refute second_user.id == first_user.id

      first_membership =
        Repo.get_by!(AccountMembership, user_id: first_user.id, account_id: account.id)

      second_membership =
        Repo.get_by!(AccountMembership, user_id: second_user.id, account_id: account.id)

      assert first_membership.role == :owner
      assert second_membership.role == :member
    end
  end

  # ----------------------------------------------------------------------
  # Post-PR-3b second re-review — CRITICAL item 1: TOCTOU race in
  # first_member_role/1 allows two :owner memberships on one Account.
  #
  # first_member_role/1 used to do an UNLOCKED `Repo.exists?` check
  # ("does this Account have any membership yet?") and only afterwards,
  # in a separate step, insert the new membership. Two concurrent
  # find_or_create_identity/1 calls for two DISTINCT external users
  # sharing the same (already-provisioned, e.g. a family account set up
  # ahead of time with no members yet) `account_id` could both observe
  # "no existing membership" before either committed, both getting
  # inserted as :owner — a privilege-escalation bug, since remove_member/3
  # and invite/3 both gate on actor.role == :owner.
  #
  # The fix takes a `FOR UPDATE` row lock on the Account row (same
  # pattern as `AccountsMembership.lock_account_for_invite/1`) as the
  # FIRST statement of the enclosing transaction — see
  # `Accounts.upsert_identity_transaction/4`'s `:account_lock` step and
  # its doc comment for why the lock must run BEFORE `:user`'s insert
  # (taking it later, right at the `Repo.exists?` check, is provably
  # correct in isolation but deadlocks — see apply-progress.md).
  #
  # Honesty note on this test's strength / why it needs real (non-sandboxed)
  # connections: Ecto's SQL Sandbox isolates each test's writes inside a
  # transaction that is rolled back at the end of the test (that's what
  # makes `async: false`/`true` tests hermetic). Under the default
  # sandboxed checkout, each spawned `Task` automatically gets its OWN
  # per-process sandbox transaction (verified manually — see
  # apply-progress.md) that can NEVER see another process's uncommitted
  # writes, INCLUDING this test's own setup fixtures. That is a real
  # concurrency (separate connections/backends genuinely racing), but it
  # can never observe a REAL row-lock conflict between racers because
  # nothing ever really commits.
  #
  # `Ecto.Adapters.SQL.Sandbox.allow/3` (the standard fix for sharing
  # in-progress test data across processes) forces every process onto
  # the SAME physical connection — which serializes all SQL onto one
  # backend and makes it structurally impossible to reproduce two
  # transactions racing on a `FOR UPDATE` lock, exactly the behavior this
  # test exists to exercise.
  #
  # So this test explicitly checks out REAL, non-sandboxed connections
  # (`sandbox: false`) for the setup phase AND for every racer task, so
  # writes are genuinely committed and visible across connections, and
  # manually cleans up every row it creates in `on_exit` (nothing here
  # auto-rolls-back). This fires N (8) genuinely concurrent
  # `find_or_create_identity/1` calls at an Account that already exists
  # (so `upsert_account/3` takes its UPDATE branch, not INSERT — the
  # INSERT branch is a distinct, out-of-scope race, see apply-progress.md)
  # but has zero memberships, for N distinct new users.
  #
  # Because Postgres's `FOR UPDATE` lock is a hard serialization
  # primitive (not a probabilistic mitigation), this test is expected to
  # pass deterministically, every run, once the fix is in place. This is
  # not a theoretical claim: while building this fix we ran this exact
  # test against the UNFIXED code and it reliably reproduced ALL 8
  # racers becoming `:owner` (not just "more than one" — every run we
  # tried); against the fixed code, we ran it 30+ times across different
  # `--seed` values with zero failures. See apply-progress.md for the
  # full RED/GREEN log, including a genuine deadlock (Postgres 40P01)
  # this same investigation surfaced and fixed (lock ordering relative
  # to the `:user` step's FK-triggered `FOR KEY SHARE`).
  # ----------------------------------------------------------------------
  describe "find_or_create_identity/1 concurrent membership race (first_member_role/1)" do
    test "at most one concurrent joiner becomes :owner when N distinct users race to join the same account" do
      # This test uses REAL (non-sandboxed) connections — see the
      # module-doc comment above for why. Nothing here auto-rolls-back,
      # so every row is cleaned up manually below. The module `setup`
      # already checked out a sandboxed connection for this process; swap
      # it for a real one.
      :ok = Sandbox.checkin(Repo)
      :ok = Sandbox.checkout(Repo, sandbox: false)
      # The plan fixtures inserted by this file's module-level `setup`
      # only committed inside the (now abandoned) sandboxed connection —
      # re-run it for real so the new non-sandboxed connection (and every
      # racer's own non-sandboxed connection below) can see them.
      :ok = MealPlannerApi.SubscriptionPlanFixtures.ensure_plans!()

      shared_external_account_id = "acct_concurrency_race_#{Ecto.UUID.generate()}"

      # Seed the Account row via one synchronous call (so upsert_account/3
      # hits the UPDATE branch, not the INSERT branch, for every racer
      # below), then delete the seed membership so the Account exists but
      # has ZERO memberships when the race starts — mirrors a
      # pre-provisioned family account whose members all log in for the
      # first time around the same moment.
      {:ok, %{account: account}} =
        Accounts.find_or_create_identity(%{
          "user_id" => "u_race_seed_throwaway",
          "account_id" => shared_external_account_id
        })

      Repo.delete_all(from(m in AccountMembership, where: m.account_id == ^account.id))

      on_exit(fn ->
        :ok = Sandbox.checkout(Repo, sandbox: false)
        Repo.delete_all(from(m in AccountMembership, where: m.account_id == ^account.id))
        Repo.delete_all(from(u in PersistenceUser, where: u.account_id == ^account.id))
        Repo.delete_all(from(a in PersistenceAccount, where: a.id == ^account.id))
        Sandbox.checkin(Repo)
      end)

      racer_user_ids = for n <- 1..8, do: "u_race_#{n}"

      tasks =
        Enum.map(racer_user_ids, fn user_id ->
          Task.async(fn ->
            :ok = Sandbox.checkout(Repo, sandbox: false)

            try do
              Accounts.find_or_create_identity(%{
                "user_id" => user_id,
                "account_id" => shared_external_account_id
              })
            after
              Sandbox.checkin(Repo)
            end
          end)
        end)

      results = Enum.map(tasks, &Task.await(&1, 10_000))

      assert Enum.all?(results, &match?({:ok, _}, &1)),
             "every racer should successfully obtain an identity: #{inspect(results)}"

      memberships =
        Repo.all(from(m in AccountMembership, where: m.account_id == ^account.id))

      owners = Enum.filter(memberships, &(&1.role == :owner))
      members = Enum.filter(memberships, &(&1.role == :member))

      assert length(memberships) == length(racer_user_ids)
      assert length(owners) == 1, "expected exactly one :owner, got: #{inspect(owners)}"
      assert length(members) == length(racer_user_ids) - 1
    end
  end

  # ----------------------------------------------------------------------
  # Post-PR-3b re-review — CRITICAL item 3: find_or_create_identity/1's 3
  # upserts (upsert_account/3, upsert_user/3, upsert_membership/2) must be
  # transactional.
  #
  # Before this fix they ran as 3 independent Repo calls inside a `with`
  # chain. If :membership failed AFTER :account/:user already committed,
  # the function fell through to {:error, :unable_to_issue_identity} with
  # NO rollback, leaving exactly the broken (account+user exist, no
  # active membership) state item 1/item 2/the whole legacy-membership-
  # synthesis fix pass exists to eliminate — now reachable via any
  # transient write failure instead of only the original design gap.
  #
  # ----------------------------------------------------------------------
  # Post-PR-3b SECOND re-review — CRITICAL item 2 (test-quality): the
  # test that used to live here built its OWN hand-rolled, separate
  # `Ecto.Multi` (same 3 step *names*, different step *bodies*) instead
  # of exercising the SHIPPED `find_or_create_identity/1`. That proved
  # generic `Ecto.Multi`/Postgres rollback semantics work — never in
  # doubt — not that the shipped function is wired correctly (right step
  # order, right `changes` keys, no swallowed errors).
  #
  # Fix: `Accounts.upsert_identity_transaction/4`'s `Multi` construction
  # was extracted into `Accounts.build_identity_multi/4` (`@doc false`,
  # public — see its doc comment) purely so tests can introspect and run
  # the REAL production `Multi`, not a copy. This describe block now has
  # 2 tests:
  #
  #   1. A genuine failure, forced through the PUBLIC
  #      `find_or_create_identity/1` API, at the real `:user` step (a
  #      `unique_constraint(:email)` violation — `users.email` has a
  #      real unique index, see `20260322090000_create_accounts_and_users.exs`).
  #      This proves the ACTUAL production transaction rolls back
  #      end-to-end when a later step fails.
  #   2. Introspection of `build_identity_multi/4`'s real `Ecto.Multi`
  #      confirming the step order is exactly
  #      `[:account_lock, :account, :user, :membership]` — i.e. this IS
  #      the same multi `find_or_create_identity/1` runs, and `:membership`
  #      genuinely is the LAST step (so failures at :account or :user,
  #      like test 1 above, are structurally equivalent evidence for a
  #      hypothetical :membership failure too: `Ecto.Multi` + `Repo.
  #      transaction/1`'s rollback-on-`{:error, _}` behavior is
  #      step-name-agnostic — it does not special-case *which* step
  #      failed).
  #
  # Honesty note — why NOT a genuine :membership-step-specific failure:
  # we looked hard for one. `upsert_membership/2` only ever calls
  # `Repo.insert/1` after `Repo.get_by(AccountMembership, user_id:,
  # account_id:)` finds NO existing row for that exact (user_id,
  # account_id) pair — and the table's only constraint on that pair
  # (`account_memberships_active_account_user_unique_index`) is scoped to
  # that SAME (user_id, account_id) key, so by construction, if `get_by`
  # found nothing, the subsequent insert cannot violate that constraint
  # either (single-threaded). `role`/`status` are hardcoded, always-valid
  # literals. The ONLY way `:membership` could fail was the genuine
  # concurrent race two DISTINCT users hitting `Repo.get_by` before
  # either committed — and that is now exactly what item 1's `FOR UPDATE`
  # lock (this same fix pass) closes. There is no remaining single- or
  # multi-threaded seam to force a :membership-only failure through the
  # public API without weakening production code, so we rely on tests 1
  # + 2 above as documented, honest, structurally-equivalent evidence.
  # ----------------------------------------------------------------------
  describe "find_or_create_identity/1 atomicity (all 3 steps roll back together)" do
    test "a real failure at the :user step rolls back the whole transaction, including :account" do
      conflicting_email = "atomicity-real-seam@example.com"

      # Pre-existing User with this email, under a DIFFERENT identity —
      # legitimate test fixture, not touching production code.
      {:ok, %{account: _other_account}} =
        Accounts.find_or_create_identity(%{
          "user_id" => "u_atomicity_seam_owner",
          "account_id" => "acct_atomicity_seam_owner",
          "email" => conflicting_email
        })

      new_external_user_id = "u_atomicity_seam_new"
      new_external_account_id = "acct_atomicity_seam_new"

      {:ok, new_db_account_id} = stable_uuid_for_test("account:" <> new_external_account_id)
      {:ok, new_db_user_id} = stable_uuid_for_test("user:" <> new_external_user_id)

      # This call's :account step WILL commit-in-progress (creates a
      # brand-new Account for new_external_account_id); its :user step
      # WILL fail — `email` collides with the pre-existing User above,
      # tripping the real `unique_constraint(:email)` — a genuine DB
      # failure via the public API, not a fabrication.
      #
      # Post-second-review fix (WARNING item 3): this same failure used
      # to log the full `%Ecto.Changeset{}` reason via raw `inspect/1`,
      # which prints `:changes` (including the PII `email` value above)
      # at `:error` level. Capture the log and assert the PII value is
      # NOT present, while the non-PII error shape still is.
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, :unable_to_issue_identity} =
                   Accounts.find_or_create_identity(%{
                     "user_id" => new_external_user_id,
                     "account_id" => new_external_account_id,
                     "email" => conflicting_email
                   })
        end)

      refute log =~ conflicting_email,
             "log must not contain the raw PII email value: #{log}"

      assert log =~ "step=:user"
      assert log =~ "has already been taken"

      # The whole transaction rolled back — including the :account row
      # that was inserted earlier in the SAME transaction, before :user
      # failed.
      refute Repo.get(PersistenceAccount, new_db_account_id)
      refute Repo.get(PersistenceUser, new_db_user_id)

      assert Repo.all(from(m in AccountMembership, where: m.account_id == ^new_db_account_id)) ==
               []
    end

    test "build_identity_multi/4 (the real production Multi) runs :account_lock, :account, :user, :membership in that order" do
      params = %{
        "email" => "introspection-fixture@example.com",
        "name" => "Introspection Fixture"
      }

      multi =
        Accounts.build_identity_multi(
          Ecto.UUID.generate(),
          Ecto.UUID.generate(),
          :individual,
          params
        )

      step_names = multi |> Multi.to_list() |> Enum.map(fn {name, _operation} -> name end)

      assert step_names == [:account_lock, :account, :user, :membership]
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

  # Local re-derivation of Accounts.stable_uuid/1 (private) purely so
  # this test file can predict the deterministic id find_or_create_identity/1
  # will use, to assert on rollback. Mirrors the production algorithm
  # exactly; if that algorithm ever changes, this needs to change too.
  defp stable_uuid_for_test(value) do
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
end
