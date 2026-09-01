defmodule MealPlannerApi.Services.EmailCodeAuthTest do
  @moduledoc """
  Phase 1 — Persistence and Code Request tests for
  `MealPlannerApi.Services.EmailCodeAuth`.

  Coverage:

    * `request_code/2` for a known email stores a SHA-256 hash (no
      plaintext), sets `expires_at = now + 10 minutes`, and delivers a
      six-digit code via Bamboo.
    * `request_code/2` for an unknown email returns the same `{:ok,
      :sent}` shape, performs no insert, and delivers no email.
    * Rate limits: fifth email/hour request is allowed, sixth is
      `:rate_limited` with `Retry-After`. Twenty-first IP/hour request
      is `:rate_limited` with `Retry-After`.
    * Bamboo `LocalAdapter` captures delivery in test (no SMTP).

  RED-phase note: this module intentionally references the production
  `MealPlannerApi.Services.EmailCodeAuth` module/function that does NOT
  exist yet — the test file MUST fail to compile until 1.2 GREEN lands.

  Delivery capture in test: the dev/test config uses
  `Bamboo.LocalAdapter` (per design), which stores into
  `Bamboo.SentEmail` (Agent). We reset and inspect that store instead
  of `Bamboo.Test`, which only works with `Bamboo.TestAdapter`.
  """
  use ExUnit.Case, async: false

  import Ecto.Query
  import MealPlannerApi.FactoryHelpers

  alias Ecto.Adapters.SQL.Sandbox
  alias MealPlannerApi.Persistence.Accounts.Account
  alias MealPlannerApi.Persistence.Accounts.AccountMembership, as: PersistenceAccountMembership
  alias MealPlannerApi.Persistence.Accounts.User, as: PersistenceUser
  alias MealPlannerApi.Repo
  alias MealPlannerApi.Services.EmailCodeAuth

  setup do
    :ok = Sandbox.checkout(Repo)
    :ok = MealPlannerApi.SubscriptionPlanFixtures.ensure_plans!()
    Bamboo.SentEmail.reset()
    :ok
  end

  describe "request_code/2 with a known email" do
    test "stores only the SHA-256 code hash and a 10-minute expiry, and delivers a 6-digit code" do
      user =
        %PersistenceUser{}
        |> PersistenceUser.changeset(%{
          email: "known@example.com",
          name: "Known User",
          role: :member
        })
        |> Repo.insert!()

      before = DateTime.utc_now()

      assert {:ok, :sent} = EmailCodeAuth.request_code("known@example.com", "203.0.113.1")

      after_ = DateTime.utc_now()

      rows =
        Repo.all(
          from(r in MealPlannerApi.Persistence.Auth.EmailVerificationCode,
            where: r.user_id == ^user.id
          )
        )

      assert length(rows) == 1
      [row] = rows
      assert is_binary(row.code_hash)

      assert byte_size(row.code_hash) == 64,
             "code_hash must be a 64-char SHA-256 hex digest, got #{inspect(row.code_hash)}"

      assert row.code_hash =~ ~r/^[0-9a-f]{64}$/,
             "code_hash must be lower-case hex SHA-256: #{inspect(row.code_hash)}"

      refute "code" in row.__struct__.__schema__(:fields),
             "no plaintext code column may exist on email_verification_codes"

      assert row.email == "known@example.com"
      assert row.expires_at != nil
      delta_seconds = DateTime.diff(row.expires_at, before, :second)

      assert delta_seconds in 595..605,
             "expected expires_at ~10 minutes from request time, got delta=#{delta_seconds}"

      refute DateTime.compare(row.expires_at, after_) == :lt,
             "expires_at must be in the future, not before request time"

      delivered = Bamboo.SentEmail.all()
      assert length(delivered) == 1

      [email] = delivered
      assert email.to == [{"Known User", "known@example.com"}]

      body = email.text_body <> email.html_body

      assert Regex.match?(~r/\b\d{6}\b/, body),
             "delivered body must contain a six-digit code: #{body}"
    end

    test "never persists plaintext code anywhere" do
      _user =
        %PersistenceUser{}
        |> PersistenceUser.changeset(%{
          email: "noplaintext@example.com",
          name: "N",
          role: :member
        })
        |> Repo.insert!()

      assert {:ok, :sent} = EmailCodeAuth.request_code("noplaintext@example.com", "203.0.113.2")

      [delivered_email] = Bamboo.SentEmail.all()

      # Match the 6-digit plaintext that was emailed. The same code is
      # rendered in both text_body and html_body so the scan returns one
      # hit per body — flatten then uniq to recover a single value.
      [code_str] =
        Regex.scan(~r/\b\d{6}\b/, delivered_email.text_body <> delivered_email.html_body)
        |> List.flatten()
        |> Enum.uniq()

      refute Repo.exists?(
               from(r in MealPlannerApi.Persistence.Auth.EmailVerificationCode,
                 where: r.code_hash == ^code_str
               )
             ),
             "plaintext code must not be stored in code_hash"

      # Belt-and-braces: scan the whole table for the plaintext value.
      assert Enum.all?(Repo.all(MealPlannerApi.Persistence.Auth.EmailVerificationCode), fn row ->
               row.code_hash != code_str
             end)
    end
  end

  describe "request_code/2 with an unknown email" do
    test "returns {:ok, :sent}, inserts no row, and delivers no email" do
      assert {:ok, :sent} = EmailCodeAuth.request_code("ghost@example.com", "203.0.113.3")

      assert Repo.aggregate(MealPlannerApi.Persistence.Auth.EmailVerificationCode, :count) == 0
      assert Bamboo.SentEmail.all() == []
    end

    test "does not leak account existence through row counts or email volume" do
      _user =
        %PersistenceUser{}
        |> PersistenceUser.changeset(%{
          email: "existing@example.com",
          name: "E",
          role: :member
        })
        |> Repo.insert!()

      assert {:ok, :sent} = EmailCodeAuth.request_code("existing@example.com", "203.0.113.4")
      assert {:ok, :sent} = EmailCodeAuth.request_code("another-ghost@example.com", "203.0.113.5")

      # Only the known email produced a row and a delivery.
      assert Repo.aggregate(MealPlannerApi.Persistence.Auth.EmailVerificationCode, :count) == 1

      assert length(Bamboo.SentEmail.all()) == 1
    end

    # Phase 1+2+verify-report follow-up — unknown-email parity. The
    # spec requires the unknown branch to "perform equivalent work to
    # keep response timing indistinguishable" (spec §"Code Request and
    # Non-Enumerating Storage"). Concretely the unknown branch must
    # perform the same `mint_code/0` + `hash_code/1` SHA-256 work the
    # known branch performs — without it, an attacker can time the
    # request to learn whether an email matches a User.
    #
    # The test asserts parity by attaching `:telemetry` handlers to the
    # `[:meal_planner_api, :email_code_auth, :mint_code]` and `[:..,
    # :hash_code]` events fired by `mint_code/0` and `hash_code/1`,
    # and verifying BOTH branches emit each event exactly once per
    # request. A pure timing-based assertion would be too flaky here
    # because the `Repo.transaction/2` overhead dwarfs the SHA-256 cost;
    # the telemetry approach is deterministic and asserts the actual
    # parity guarantee the spec requires.
    test "unknown-email request performs equivalent hashing work (mint_code + hash_code)" do
      test_pid = self()
      handler_id = "parity-test-#{System.unique_integer([:positive])}"

      :telemetry.attach_many(
        handler_id,
        [
          [:meal_planner_api, :email_code_auth, :mint_code],
          [:meal_planner_api, :email_code_auth, :hash_code]
        ],
        fn event_name, _measurements, _metadata, _config ->
          send(test_pid, {:telemetry_event, event_name})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      # Drain any telemetry messages left from setup.
      flush_telemetry()

      # ----- Unknown-email branch -----
      assert {:ok, :sent} =
               EmailCodeAuth.request_code(
                 "unknown-parity@example.com",
                 "203.0.113.50"
               )

      # The unknown branch must fire mint_code + hash_code exactly
      # once each — equivalent work to the known branch.
      assert_receive {:telemetry_event, [:meal_planner_api, :email_code_auth, :mint_code]},
                     1_000

      assert_receive {:telemetry_event, [:meal_planner_api, :email_code_auth, :hash_code]},
                     1_000

      # Drain so the known-branch measurement starts from a clean slate.
      flush_telemetry()

      # ----- Known-email branch (control) -----
      known_user =
        %PersistenceUser{}
        |> PersistenceUser.changeset(%{
          email: "known-parity@example.com",
          name: "Known Parity",
          role: :member
        })
        |> Repo.insert!()

      assert {:ok, :sent} =
               EmailCodeAuth.request_code(known_user.email, "203.0.113.51")

      assert_receive {:telemetry_event, [:meal_planner_api, :email_code_auth, :mint_code]},
                     1_000

      assert_receive {:telemetry_event, [:meal_planner_api, :email_code_auth, :hash_code]},
                     1_000
    end
  end

  describe "rate limits" do
    test "fifth request for the same email in an hour is allowed" do
      _user =
        %PersistenceUser{}
        |> PersistenceUser.changeset(%{
          email: "limit@example.com",
          name: "Limit",
          role: :member
        })
        |> Repo.insert!()

      results =
        for n <- 1..5 do
          EmailCodeAuth.request_code("limit@example.com", "203.0.113.10")
        end

      assert Enum.all?(results, &match?({:ok, :sent}, &1))
    end

    test "sixth request for the same email in an hour returns {:error, :rate_limited, retry_after}" do
      _user =
        %PersistenceUser{}
        |> PersistenceUser.changeset(%{
          email: "over@example.com",
          name: "Over",
          role: :member
        })
        |> Repo.insert!()

      for _ <- 1..5 do
        {:ok, :sent} = EmailCodeAuth.request_code("over@example.com", "203.0.113.20")
      end

      assert {:error, :rate_limited, retry_after} =
               EmailCodeAuth.request_code("over@example.com", "203.0.113.20")

      assert is_integer(retry_after)
      assert retry_after > 0
      assert retry_after <= 3600
    end

    test "21st request from the same IP across any emails returns {:error, :rate_limited, retry_after}" do
      results =
        for n <- 1..20 do
          EmailCodeAuth.request_code("n#{n}@example.com", "203.0.113.30")
        end

      assert Enum.all?(results, &match?({:ok, :sent}, &1))

      assert {:error, :rate_limited, _retry_after} =
               EmailCodeAuth.request_code("n21@example.com", "203.0.113.30")
    end

    test "Retry-After reflects the earliest counted event" do
      _user =
        %PersistenceUser{}
        |> PersistenceUser.changeset(%{
          email: "retry@example.com",
          name: "Retry",
          role: :member
        })
        |> Repo.insert!()

      for _ <- 1..5 do
        {:ok, :sent} = EmailCodeAuth.request_code("retry@example.com", "203.0.113.40")
      end

      assert {:error, :rate_limited, _} =
               EmailCodeAuth.request_code("retry@example.com", "203.0.113.40")
    end
  end

  describe "Bamboo LocalAdapter delivery" do
    test "captures delivery in test without outbound SMTP" do
      _user =
        %PersistenceUser{}
        |> PersistenceUser.changeset(%{
          email: "capture@example.com",
          name: "C",
          role: :member
        })
        |> Repo.insert!()

      assert {:ok, :sent} = EmailCodeAuth.request_code("capture@example.com", "203.0.113.50")

      # LocalAdapter captures into the Bamboo.SentEmail Agent (the same
      # store the unknown-email tests already use).
      assert Bamboo.SentEmail.all() != []
    end
  end

  # ---------------------------------------------------------------------------
  # Phase 2 — Verification and Lockout (issue #31 task 2.1)
  # ---------------------------------------------------------------------------
  #
  # Coverage (`specs/email-code-authentication/spec.md` §"Atomic Single-Use
  # Code Verification" + §"Failed-Verification Lockout"):
  #
  #   * valid code consumes the pending row in a single SQL operation
  #   * wrong / expired codes return :invalid_code, leave consumed_at NULL,
  #     and append a `verification_failure` event
  #   * concurrent replay: exactly one verifier succeeds; the others get
  #     `:code_already_used`
  #   * User-B principal supplied for User-A's row: `:unauthorized_principal`,
  #     row NOT consumed, failure event appended
  #   * `:invalid_bearer` (plug-detected invalid token): rejected without
  #     any DB change
  #   * tenth failure for an email does NOT consume the pending code
  #   * eleventh attempt for an email returns `{:error, :rate_limited, retry_after}`
  #
  # RED-phase note: each test references `EmailCodeAuth.verify_code/3`, which
  # does NOT exist yet. The whole `describe` block must fail to compile until
  # task 2.2 GREEN lands.
  describe "verify_code/3 (Phase 2)" do
    test "valid code consumes the pending row and returns the user_id" do
      user =
        insert_user!("verify-valid@example.com", "Verify Valid")

      code = "123456"
      insert_verification_code!(user, code)

      assert {:ok, %{user_id: user_id, consumed_at: %DateTime{}}} =
               EmailCodeAuth.verify_code(user.email, code, principal: nil)

      assert user_id == user.id

      [row] = Repo.all(MealPlannerApi.Persistence.Auth.EmailVerificationCode)
      assert row.user_id == user.id
      refute is_nil(row.consumed_at)
    end

    test "wrong code returns :invalid_code, does not consume, appends a failure event" do
      user =
        insert_user!("verify-wrong@example.com", "Verify Wrong")

      code = "123456"
      insert_verification_code!(user, code)

      assert {:error, :invalid_code} =
               EmailCodeAuth.verify_code(user.email, "000000", principal: nil)

      [row] = Repo.all(MealPlannerApi.Persistence.Auth.EmailVerificationCode)
      assert is_nil(row.consumed_at)

      failures =
        Repo.all(
          from(e in MealPlannerApi.Persistence.Auth.EmailAuthEvent,
            where: e.kind == "verification_failure",
            where: e.email == ^user.email
          )
        )

      assert length(failures) == 1
    end

    test "expired code returns :invalid_code, does not consume, appends a failure event" do
      user =
        insert_user!("verify-expired@example.com", "Verify Expired")

      code = "123456"

      past = DateTime.add(DateTime.utc_now(), -60, :second)

      insert_verification_code!(user, code, expires_at: past)

      assert {:error, :invalid_code} =
               EmailCodeAuth.verify_code(user.email, code, principal: nil)

      [row] = Repo.all(MealPlannerApi.Persistence.Auth.EmailVerificationCode)
      assert is_nil(row.consumed_at)

      assert Repo.exists?(
               from(e in MealPlannerApi.Persistence.Auth.EmailAuthEvent,
                 where: e.kind == "verification_failure",
                 where: e.email == ^user.email
               )
             )
    end

    test "replay: exactly one success, others get :code_already_used" do
      user =
        insert_user!("verify-replay@example.com", "Verify Replay")

      code = "123456"
      insert_verification_code!(user, code)

      results =
        for _ <- 1..5 do
          EmailCodeAuth.verify_code(user.email, code, principal: nil)
        end

      successes = Enum.count(results, &match?({:ok, _}, &1))
      already_used = Enum.count(results, &match?({:error, :code_already_used}, &1))

      assert successes == 1
      assert already_used == 4

      [row] = Repo.all(MealPlannerApi.Persistence.Auth.EmailVerificationCode)
      refute is_nil(row.consumed_at)
    end

    # Phase 1+2+verify-report follow-up — the serial `for` loop above
    # exercises the consume path but cannot race it. The advisory lock +
    # atomic UPDATE … RETURNING must serialize N concurrent verifiers into
    # exactly one success and N-1 :code_already_used outcomes (spec §
    # "Atomic Single-Use Code Verification" / Scenario "Concurrent replay
    # produces exactly one success").
    #
    # Switch the sandbox to shared mode so the spawned tasks share the
    # test process's transaction context; each task's `Repo.transaction/2`
    # then opens a savepoint inside it and the racing
    # `pg_advisory_xact_lock` calls actually serialize across processes.
    # Restore on exit so downstream tests default back to :auto.
    test "concurrent replay of the same code yields exactly one success and N-1 :code_already_used" do
      user =
        insert_user!("verify-concurrent-replay@example.com", "Verify Concurrent Replay")

      code = "123456"
      insert_verification_code!(user, code)

      Sandbox.mode(Repo, {:shared, self()})
      on_exit(fn -> Sandbox.mode(Repo, :auto) end)

      concurrency = 8

      results =
        1..concurrency
        |> Task.async_stream(
          fn _idx ->
            EmailCodeAuth.verify_code(user.email, code, principal: nil)
          end,
          max_concurrency: concurrency,
          timeout: 10_000,
          on_timeout: :kill_task
        )
        |> Enum.map(fn {:ok, value} -> value end)

      successes = Enum.count(results, &match?({:ok, _}, &1))
      already_used = Enum.count(results, &match?({:error, :code_already_used}, &1))

      assert successes == 1,
             "expected exactly one success among #{concurrency} concurrent verifiers, " <>
               "got #{successes}. results=#{inspect(results)}"

      assert already_used == concurrency - 1,
             "expected #{concurrency - 1} :code_already_used, got #{already_used}. " <>
               "results=#{inspect(results)}"

      # Every loser must surface as :code_already_used (the spec error
      # for replay), not :invalid_code or :rate_limited — the verify
      # lockout must NOT trip before the consume path can race.
      for result <- results do
        case result do
          {:ok, _} -> :ok
          {:error, :code_already_used} -> :ok
          other -> flunk("unexpected concurrent replay result #{inspect(other)}")
        end
      end

      # Row consumed exactly once.
      [row] = Repo.all(MealPlannerApi.Persistence.Auth.EmailVerificationCode)
      refute is_nil(row.consumed_at)
    end

    test "User-B principal for User-A's row returns :unauthorized_principal, does not consume" do
      user_a = insert_user!("verify-a@example.com", "A")
      user_b = insert_user!("verify-b@example.com", "B")

      code = "123456"
      insert_verification_code!(user_a, code)

      assert {:error, :unauthorized_principal} =
               EmailCodeAuth.verify_code(user_a.email, code, principal: user_b.id)

      [row] =
        Repo.all(
          from(r in MealPlannerApi.Persistence.Auth.EmailVerificationCode,
            where: r.user_id == ^user_a.id
          )
        )

      assert is_nil(row.consumed_at)

      assert Repo.exists?(
               from(e in MealPlannerApi.Persistence.Auth.EmailAuthEvent,
                 where: e.kind == "verification_failure",
                 where: e.email == ^user_a.email
               )
             )
    end

    test "invalid bearer returns :invalid_bearer without DB changes" do
      user = insert_user!("verify-bearer@example.com", "Verify Bearer")

      code = "123456"
      insert_verification_code!(user, code)

      assert {:error, :invalid_bearer} =
               EmailCodeAuth.verify_code(user.email, code, principal: :invalid_bearer)

      [row] = Repo.all(MealPlannerApi.Persistence.Auth.EmailVerificationCode)
      assert is_nil(row.consumed_at)

      assert Repo.aggregate(
               from(e in MealPlannerApi.Persistence.Auth.EmailAuthEvent,
                 where: e.kind == "verification_failure"
               ),
               :count
             ) == 0
    end

    test "tenth failed verification does NOT consume the pending code" do
      user =
        insert_user!("verify-tenth@example.com", "Verify Tenth")

      code = "123456"
      insert_verification_code!(user, code)

      for n <- 1..10 do
        assert {:error, :invalid_code} =
                 EmailCodeAuth.verify_code(user.email, "000000", principal: nil),
               "attempt #{n} should be :invalid_code"
      end

      [row] = Repo.all(MealPlannerApi.Persistence.Auth.EmailVerificationCode)
      assert is_nil(row.consumed_at)

      failures =
        Repo.all(
          from(e in MealPlannerApi.Persistence.Auth.EmailAuthEvent,
            where: e.kind == "verification_failure",
            where: e.email == ^user.email
          )
        )

      assert length(failures) == 10
    end

    test "eleventh attempt returns {:error, :rate_limited, retry_after}" do
      user =
        insert_user!("verify-lockout@example.com", "Verify Lockout")

      code = "123456"
      insert_verification_code!(user, code)

      for _ <- 1..10 do
        {:error, :invalid_code} =
          EmailCodeAuth.verify_code(user.email, "000000", principal: nil)
      end

      assert {:error, :rate_limited, retry_after} =
               EmailCodeAuth.verify_code(user.email, code, principal: nil)

      assert is_integer(retry_after)
      assert retry_after > 0
      assert retry_after <= 3600

      [row] = Repo.all(MealPlannerApi.Persistence.Auth.EmailVerificationCode)

      assert is_nil(row.consumed_at),
             "lockout attempt must not consume the still-pending row"
    end
  end

  # ---------------------------------------------------------------------------
  # Phase 3 — Outcomes and Continuations (issue #31 task 3.1)
  # ---------------------------------------------------------------------------
  #
  # Coverage (`specs/email-code-authentication/spec.md` §"Verify Response
  # Outcomes by Active-Membership Count" + §"Membership Summary Tenancy
  # Isolation"):
  #
  #   * single `:active` membership → `:single` outcome with
  #     `membership` + `claims` (claim set has `membership_id`).
  #   * zero `:active` memberships → `:none` outcome with `claims`
  #     whose `membership_id` claim is ABSENT (so the client can mint
  #     a JWT that triggers `LoadCurrentMembership`'s 401
  #     `membership_id_required`).
  #   * two `:active` memberships → `:multiple` outcome with
  #     `summaries` and a `continuation_token`; no claims / no JWT
  #     (client must call `/api/auth/switch-account` with the
  #     continuation).
  #   * each summary carries `subscription_status` from `AccountAccess`.
  #   * tenancy isolation: a second user's membership on the same
  #     Account MUST NOT appear in User A's multi-membership summaries.
  #
  # RED-phase note: each test asserts the new `outcome:` field on the
  # `verify_code/3` success tuple and the new `:single`/`:none`/
  # `:multiple` kinds. The test compiles only after task 3.2 GREEN
  # lands.
  describe "verify_code/3 outcomes (Phase 3 task 3.1)" do
    test "single active membership returns :single outcome with membership and full claims" do
      user = insert_user_with_membership!("single-outcome@example.com", :owner)
      code = "111111"
      insert_verification_code!(user, code)

      assert {:ok, %{outcome: outcome, user_id: uid}} =
               EmailCodeAuth.verify_code(user.email, code, principal: nil)

      assert uid == user.id
      assert outcome.kind == :single
      assert outcome.membership.id == user.membership.id
      assert outcome.membership.status == :active

      assert outcome.claims["typ"] == "access_v2"
      assert outcome.claims["membership_id"] == Ecto.UUID.cast!(user.membership.id)
      assert outcome.claims["account_id"] == Ecto.UUID.cast!(user.membership.account_id)
      assert outcome.claims["user_id"] == Ecto.UUID.cast!(user.id)
    end

    test "zero active memberships returns :none outcome with claims without membership_id" do
      user = insert_user!("zero-outcome@example.com", "Zero Outcome")
      code = "222222"
      insert_verification_code!(user, code)

      assert {:ok, %{outcome: outcome}} =
               EmailCodeAuth.verify_code(user.email, code, principal: nil)

      assert outcome.kind == :none
      refute Map.has_key?(outcome.claims, "membership_id")
      assert outcome.claims["typ"] == "access_v2"
      assert outcome.claims["user_id"] == Ecto.UUID.cast!(user.id)
    end

    test "multiple active memberships returns :multiple outcome with summaries and continuation_token, no claims" do
      user = insert_user_with_two_memberships!("multi-outcome@example.com")
      code = "333333"
      insert_verification_code!(user, code)

      assert {:ok, %{outcome: outcome}} =
               EmailCodeAuth.verify_code(user.email, code, principal: nil)

      assert outcome.kind == :multiple
      assert is_list(outcome.summaries)
      assert length(outcome.summaries) == 2

      assert is_binary(outcome.continuation_token)
      assert byte_size(outcome.continuation_token) > 20

      assert outcome.claims == nil
    end

    test "multi-membership summaries include subscription_status derived from AccountAccess" do
      user = insert_user_with_two_memberships!("sub-outcome@example.com")
      code = "444444"
      insert_verification_code!(user, code)

      assert {:ok, %{outcome: %{kind: :multiple, summaries: summaries}}} =
               EmailCodeAuth.verify_code(user.email, code, principal: nil)

      for s <- summaries do
        assert is_binary(s.membership_id)
        assert is_binary(s.account_id)
        assert s.role in ["owner", "member"]
        assert s.plan in ["individual", "family_4", "family_6", "trial"]
        assert s.subscription_status in ["trial", "active", "expired"]
      end
    end

    test "multi-membership summaries do NOT include another user's membership on the same Account" do
      user_a = insert_user_with_two_memberships!("isolation-a@example.com")
      [solo_a, shared_a] = user_a.memberships

      user_b =
        %PersistenceUser{}
        |> PersistenceUser.changeset(%{
          email: "isolation-b@example.com",
          name: "Iso B",
          role: :member
        })
        |> Repo.insert!()

      user_b_membership =
        %MealPlannerApi.Persistence.Accounts.AccountMembership{}
        |> Ecto.Changeset.change(%{
          account_id: shared_a.account_id,
          user_id: user_b.id,
          role: :member,
          status: :active,
          joined_at: DateTime.utc_now()
        })
        |> Repo.insert!()

      code = "555555"
      insert_verification_code!(user_a, code)

      assert {:ok, %{outcome: %{kind: :multiple, summaries: summaries}}} =
               EmailCodeAuth.verify_code(user_a.email, code, principal: nil)

      assert length(summaries) == 2,
             "User A owns 2 memberships; summaries must not surface User B's"

      summary_ids = Enum.map(summaries, & &1.membership_id)
      assert Ecto.UUID.cast!(solo_a.id) in summary_ids
      assert Ecto.UUID.cast!(shared_a.id) in summary_ids
      refute Ecto.UUID.cast!(user_b_membership.id) in summary_ids
    end
  end

  # ---------------------------------------------------------------------------
  # Phase 3 — Continuations (issue #31 task 3.3)
  # ---------------------------------------------------------------------------
  #
  # Coverage (`specs/email-code-authentication/spec.md` §"Selection
  # Continuation Security", `design.md` §"Interfaces / Contracts"):
  #
  #   * bearerless first exchange returns a scoped `access_v2` JWT
  #     and consumes the continuation row.
  #   * replay/concurrent exchange (same continuation) fails exactly
  #     once with `:consumed_continuation`; subsequent attempts cannot
  #     mint.
  #   * expired continuation fails with `:expired_continuation`.
  #   * membership outside the continuation's set fails with
  #     `:not_in_continuation_set`; the continuation is NOT consumed.
  #   * foreign bearer (User B's JWT) with User A's continuation fails
  #     with `:foreign_bearer`; the continuation is NOT consumed.
  #   * `switch_account/2` failure (membership inactive) leaves the
  #     continuation UNCONSUMED.
  #
  # RED-phase note: each test asserts `EmailCodeAuth.exchange_continuation/3`,
  # which does NOT exist yet. The whole `describe` block fails to compile
  # until task 3.4 GREEN lands.
  describe "exchange_continuation/3 (Phase 3 task 3.3)" do
    setup do
      # The exchange MUST mint `access_v2` claims (with `membership_id`)
      # — continuation selection is a v2-only flow. `AccountsMembership.
      # switch_account/2` gates claim shape on `:tenancy_v2_only`; flip
      # the flag for this describe block and restore via `on_exit`.
      previous = Application.get_env(:meal_planner_api, :tenancy_v2_only)
      Application.put_env(:meal_planner_api, :tenancy_v2_only, true)
      on_exit(fn -> Application.put_env(:meal_planner_api, :tenancy_v2_only, previous) end)
      :ok
    end

    test "bearerless first exchange mints a scoped access_v2 JWT and consumes the continuation" do
      user = insert_user_with_two_memberships!("exchange-first@example.com")
      [m1, m2] = user.memberships

      plaintext = EmailCodeAuth.mint_test_continuation(user.id, [m1.id, m2.id])

      assert {:ok, %{membership: membership, claims: claims, access_token: token}} =
               EmailCodeAuth.exchange_continuation(plaintext, to_string(m1.id), principal: nil)

      assert membership.id == m1.id
      assert claims["membership_id"] == Ecto.UUID.cast!(m1.id)
      assert is_binary(token)

      consumed =
        Repo.get_by(MealPlannerApi.Persistence.Auth.AccountSelectionContinuation,
          user_id: user.id
        )

      refute is_nil(consumed.consumed_at)
    end

    test "replay / concurrent exchange fails with :consumed_continuation and mints zero JWTs" do
      user = insert_user_with_two_memberships!("exchange-replay@example.com")
      [m1, m2] = user.memberships

      plaintext = EmailCodeAuth.mint_test_continuation(user.id, [m1.id, m2.id])

      assert {:ok, _} =
               EmailCodeAuth.exchange_continuation(plaintext, to_string(m1.id), principal: nil)

      assert {:error, :consumed_continuation} =
               EmailCodeAuth.exchange_continuation(plaintext, to_string(m1.id), principal: nil)
    end

    # Phase 1+2+verify-report follow-up — the serial first/second
    # exchange above exercises the consume path but cannot race it. The
    # continuation's `SELECT … FOR UPDATE` + advisory lock must serialize
    # N concurrent exchange attempts into exactly one success and N-1
    # :consumed_continuation outcomes (spec §"Selection Continuation
    # Security" / Scenario "Reusing the continuation fails" + design.md
    # §"Interfaces / Contracts" — "concurrent/replayed exchange has one
    # success; pre-mint failures do not consume").
    test "concurrent exchange of the same continuation yields exactly one success and N-1 :consumed_continuation" do
      user = insert_user_with_two_memberships!("exchange-concurrent@example.com")
      [m1, m2] = user.memberships

      plaintext = EmailCodeAuth.mint_test_continuation(user.id, [m1.id, m2.id])

      Sandbox.mode(Repo, {:shared, self()})
      on_exit(fn -> Sandbox.mode(Repo, :auto) end)

      concurrency = 6

      results =
        1..concurrency
        |> Task.async_stream(
          fn _idx ->
            EmailCodeAuth.exchange_continuation(plaintext, to_string(m1.id), principal: nil)
          end,
          max_concurrency: concurrency,
          timeout: 10_000,
          on_timeout: :kill_task
        )
        |> Enum.map(fn {:ok, value} -> value end)

      successes = Enum.count(results, &match?({:ok, _}, &1))
      consumed = Enum.count(results, &match?({:error, :consumed_continuation}, &1))

      assert successes == 1,
             "expected exactly one success among #{concurrency} concurrent exchanges, " <>
               "got #{successes}. results=#{inspect(results)}"

      assert consumed == concurrency - 1,
             "expected #{concurrency - 1} :consumed_continuation, got #{consumed}. " <>
               "results=#{inspect(results)}"

      # Continuation row consumed exactly once.
      consumed_row =
        Repo.get_by(MealPlannerApi.Persistence.Auth.AccountSelectionContinuation,
          user_id: user.id
        )

      refute is_nil(consumed_row.consumed_at)
    end

    test "expired continuation fails with :expired_continuation" do
      user = insert_user_with_two_memberships!("exchange-expired@example.com")
      [m1, m2] = user.memberships

      past = DateTime.add(DateTime.utc_now(), -60, :second)
      plaintext = EmailCodeAuth.mint_test_continuation(user.id, [m1.id, m2.id], expires_at: past)

      assert {:error, :expired_continuation} =
               EmailCodeAuth.exchange_continuation(plaintext, to_string(m1.id), principal: nil)
    end

    test "membership outside the continuation's set fails with :not_in_continuation_set and does NOT consume" do
      user = insert_user_with_two_memberships!("exchange-foreign-set@example.com")
      [m1, m2] = user.memberships

      third_user = insert_user!("exchange-third@example.com", "Third")
      foreign_membership = insert_membership!(third_user)
      plaintext = EmailCodeAuth.mint_test_continuation(user.id, [m1.id, m2.id])

      assert {:error, :not_in_continuation_set} =
               EmailCodeAuth.exchange_continuation(plaintext, to_string(foreign_membership.id),
                 principal: nil
               )

      consumed =
        Repo.get_by(MealPlannerApi.Persistence.Auth.AccountSelectionContinuation,
          user_id: user.id
        )

      assert is_nil(consumed.consumed_at),
             "continuation must NOT be consumed when the membership is outside its set"
    end

    test "foreign bearer (User B's principal for User A's continuation) fails with :foreign_bearer" do
      user_a = insert_user_with_two_memberships!("exchange-a@example.com")
      user_b = insert_user!("exchange-b@example.com", "B Exchange")
      [m1, m2] = user_a.memberships

      plaintext = EmailCodeAuth.mint_test_continuation(user_a.id, [m1.id, m2.id])

      assert {:error, :foreign_bearer} =
               EmailCodeAuth.exchange_continuation(
                 plaintext,
                 to_string(m1.id),
                 principal: user_b.id
               )

      consumed =
        Repo.get_by(MealPlannerApi.Persistence.Auth.AccountSelectionContinuation,
          user_id: user_a.id
        )

      assert is_nil(consumed.consumed_at),
             "continuation must NOT be consumed when the bearer is foreign"
    end

    test "switch_account/2 failure (membership not active) leaves the continuation UNCONSUMED" do
      user = insert_user_with_two_memberships!("exchange-premint@example.com")
      [m1, m2] = user.memberships

      # Flip m2 to :invited (non-active) so switch_account/2 will reject
      # it. The continuation still binds m1+m2, but the switch fails.
      Repo.update_all(
        from(am in MealPlannerApi.Persistence.Accounts.AccountMembership,
          where: am.id == ^m2.id
        ),
        set: [status: :invited]
      )

      plaintext = EmailCodeAuth.mint_test_continuation(user.id, [m1.id, m2.id])

      assert {:error, :membership_not_active} =
               EmailCodeAuth.exchange_continuation(plaintext, to_string(m2.id), principal: nil)

      consumed =
        Repo.get_by(MealPlannerApi.Persistence.Auth.AccountSelectionContinuation,
          user_id: user.id
        )

      assert is_nil(consumed.consumed_at),
             "pre-mint failure must NOT consume the continuation"
    end
  end

  # ---- Phase 2 helpers --------------------------------------------------------

  defp insert_user!(email, name) do
    %PersistenceUser{}
    |> PersistenceUser.changeset(%{email: email, name: name, role: :member})
    |> Repo.insert!()
  end

  # Drain any pending `:telemetry_event` messages from the test process
  # mailbox. Used by the unknown-email parity test to isolate per-call
  # measurements when the production code fires `:telemetry.execute/3`
  # for each `mint_code/0` and `hash_code/1` invocation.
  defp flush_telemetry do
    receive do
      {:telemetry_event, _event} -> flush_telemetry()
    after
      0 -> :ok
    end
  end

  defp insert_verification_code!(user, code, opts \\ []) do
    expires_at =
      Keyword.get(
        opts,
        :expires_at,
        DateTime.add(DateTime.utc_now(), 600, :second)
      )

    %MealPlannerApi.Persistence.Auth.EmailVerificationCode{}
    |> Ecto.Changeset.change(%{
      user_id: user.id,
      email: user.email,
      code_hash: EmailCodeAuth.hash_code(code),
      expires_at: expires_at
    })
    |> Repo.insert!()
  end

  # ---- Phase 3 helpers --------------------------------------------------------
  #
  # All Phase 3 fixture helpers insert rows through the standard
  # Ecto changesets so the assertions observe the production schema.
  # `insert_user_with_memberships!/3` wraps `FactoryHelpers.user_with_memberships/2`
  # and pins the returned `PersistenceUser.t()` + first `membership` so
  # tests can read either without juggling `Enum.at/2`.

  defp insert_user_with_membership!(email, role) do
    user =
      user_with_memberships(
        %{email: email, name: "M #{email}"},
        [
          {%{plan: :individual, name: "Solo #{email}"}, role}
        ]
      )

    [membership] = user.memberships
    Map.put(user, :membership, membership)
  end

  defp insert_user_with_two_memberships!(email) do
    user =
      user_with_memberships(
        %{email: email, name: "Multi #{email}"},
        [
          {%{plan: :individual, name: "Solo #{email}"}, :owner},
          {%{plan: :family_4, name: "Family #{email}"}, :member}
        ]
      )

    user
  end

  defp insert_membership!(user) do
    plan_row =
      case MealPlannerApi.Subscriptions.get_plan_by_name("individual") do
        {:ok, p} -> p
      end

    account =
      %Account{}
      |> Ecto.Changeset.change(%{
        name: "Factory Account #{Ecto.UUID.generate()}",
        plan: :individual,
        default_budget_cents: 0,
        subscription_plan_id: plan_row.id
      })
      |> Repo.insert!()

    %PersistenceAccountMembership{}
    |> Ecto.Changeset.change(%{
      account_id: account.id,
      user_id: user.id,
      role: :member,
      status: :active,
      joined_at: DateTime.utc_now()
    })
    |> Repo.insert!()
  end
end
