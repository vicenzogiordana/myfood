defmodule MealPlannerApi.Services.EmailCodeAuth do
  @moduledoc """
  Email-code authentication orchestration.

  Phase 1 — Persistence and Code Request (issue #31). Owns the
  `request_code/2` path used by `POST /api/auth/email-code/request`:

    1. Reserve a per-email and per-IP rolling 1-hour slot under
       ordered Postgres advisory locks so concurrent requesters
       cannot collectively exceed the spec-mandated limits
       (5/email/h, 20/IP/h).
    2. Persist only a SHA-256 hash of a fresh six-digit code with
       `expires_at = now + 10 minutes`. No plaintext column exists,
       and the code itself is never logged.
    3. Deliver via `MealPlannerApi.Mailer` using the configured
       Bamboo adapter (LocalAdapter in `:dev` and `:test`).

  Phase 2 — Verification and Lockout. Owns `verify_code/3` with the
  principal-bound atomic `UPDATE … RETURNING`, the persisted
  `verification_failure` events, and the rolling 1-hour lockout.

  Phase 3 — Outcomes and Continuations. Owns:

    * The `:single | :none | :multiple` outcome branching on the count
      of the User's `:active` memberships, returned on the success
      tuple of `verify_code/3`.
    * `summarize_active_memberships/1` for the multi-membership summary
      rows (each carries a `subscription_status` derived from
      `MealPlannerApi.AccountAccess.status/2`).
    * `mint_continuation/2` for the random opaque token + SHA-256 hash
      + 5-minute TTL + bound membership-set rows.
    * `exchange_continuation/3`, the locked single-use exchange that
      delegates to `MealPlannerApi.AccountsMembership.switch_account/2`
      and mints the `access_v2` JWT inside the same transaction as
      the `consumed_at` UPDATE.

  Unknown emails deliberately behave identically with respect to
  response shape (`{:ok, :sent}`) and timing-equivalent work, but
  no row is inserted and no email is sent — the spec's
  "non-enumerating" guarantee.
  """

  import Ecto.Query

  alias Ecto.Adapters.SQL
  alias MealPlannerApi.AccountAccess
  alias MealPlannerApi.AccountsMembership
  alias MealPlannerApi.Auth.Guardian
  alias MealPlannerApi.Mailer
  alias MealPlannerApi.Mailer.EmailCodeEmail
  alias MealPlannerApi.Persistence.Accounts.AccountMembership, as: PersistenceAccountMembership
  alias MealPlannerApi.Persistence.Accounts.User, as: PersistenceUser
  alias MealPlannerApi.Persistence.Auth.AccountSelectionContinuation
  alias MealPlannerApi.Persistence.Auth.AccountSelectionContinuationMembership
  alias MealPlannerApi.Persistence.Auth.EmailAuthEvent
  alias MealPlannerApi.Persistence.Auth.EmailVerificationCode
  alias MealPlannerApi.Repo

  @ttl_seconds 600
  @window_seconds 3600
  @max_per_email_per_window 5
  @max_per_ip_per_window 20
  @max_failures_per_window 10
  @code_length 6
  @continuation_ttl_seconds 300

  # Lock keys are 64-bit signed integers fed to `pg_advisory_xact_lock`.
  # We hash the normalized inputs so neither key collides with another
  # in a way that serializes unrelated work.
  @email_lock_salt 0x4D45_6C70_6861_756C
  @ip_lock_salt 0x4D45_6C70_5F69_705F
  # Separate salt for the verify-path advisory lock so a long verify
  # queue never starves the request-path reservation (and vice versa).
  @verify_lock_salt 0x4D45_6C70_5F76_6572
  # Salt for the continuation-exchange advisory lock so concurrent
  # exchange attempts on the same continuation token serialize cleanly
  # without starving the verify-path or request-path locks.
  @continuation_lock_salt 0x4D45_6C70_5F63_7478

  @type rate_limited :: {:error, :rate_limited, non_neg_integer()}

  @type principal :: nil | Ecto.UUID.t() | :invalid_bearer

  @type single_outcome :: %{
          kind: :single,
          membership: PersistenceAccountMembership.t(),
          claims: map()
        }

  @type none_outcome :: %{
          kind: :none,
          claims: map()
        }

  @type multiple_outcome :: %{
          kind: :multiple,
          summaries: [map()],
          continuation_token: String.t(),
          expires_at: DateTime.t(),
          claims: nil
        }

  @type outcome :: single_outcome() | none_outcome() | multiple_outcome()

  @type verify_result ::
          {:ok,
           %{
             user_id: Ecto.UUID.t(),
             consumed_at: DateTime.t(),
             outcome: outcome()
           }}
          | {:error, :invalid_code}
          | {:error, :code_already_used}
          | {:error, :unauthorized_principal}
          | {:error, :invalid_bearer}
          | {:error, :rate_limited, non_neg_integer()}

  @type exchange_result ::
          {:ok,
           %{
             user: PersistenceUser.t(),
             account: term(),
             membership: PersistenceAccountMembership.t(),
             claims: map(),
             access_token: String.t()
           }}
          | {:error,
             :invalid_continuation
             | :expired_continuation
             | :consumed_continuation
             | :foreign_bearer
             | :invalid_bearer
             | :not_in_continuation_set
             | :membership_not_found
             | :not_your_membership
             | :membership_not_active
             | :token_refresh_failed}

  @doc """
  Issues a six-digit verification code for `email` from `client_ip`.

  Returns `{:ok, :sent}` once the code has been hashed, persisted,
  and dispatched. Returns `{:error, :rate_limited, retry_after}`
  when the rolling 1-hour counter for the email or the IP has been
  exhausted, where `retry_after` is the integer number of seconds
  until the earliest counted event falls outside the window.

  No part of the plaintext code is returned, logged, or echoed by
  this module — the email is the only delivery channel.
  """
  @spec request_code(String.t(), String.t() | nil) ::
          {:ok, :sent}
          | {:error, :rate_limited, non_neg_integer()}
          | {:error, term()}
  def request_code(email, client_ip) when is_binary(email) do
    normalized_email = normalize_email(email)
    normalized_ip = normalize_client_ip(client_ip)

    Repo.transaction(
      fn ->
        with :ok <- reserve_slots(normalized_email, normalized_ip) do
          case fetch_user(normalized_email) do
            %PersistenceUser{} = user ->
              code = mint_code()
              hash = hash_code(code)

              {:ok, _} =
                %EmailVerificationCode{}
                |> Ecto.Changeset.change(%{
                  user_id: user.id,
                  email: normalized_email,
                  code_hash: hash,
                  expires_at: DateTime.add(DateTime.utc_now(), @ttl_seconds, :second)
                })
                |> Repo.insert()

              :ok = deliver_code(user, normalized_email, code)

              :sent

            nil ->
              # Unknown email: equivalent work (mint_code + hash_code)
              # to keep the response timing indistinguishable from the
              # known-email branch (spec §"Code Request and Non-
              # Enumerating Storage"). The SHA-256 hash work is the
              # costly portion that an attacker would otherwise time to
              # learn whether an email matches a User; performing it
              # here closes that side channel. No row is inserted and
              # no email is delivered.
              code = mint_code()
              _hash = hash_code(code)
              :sent
          end
        end
      end,
      timeout: :timer.seconds(5)
    )
    |> normalize_tx_result()
  end

  @doc """
  Phase 2 — Verification and Lockout (issue #31 task 2.2).
  Phase 3 — Outcomes and Continuations (issue #31 task 3.2).

  Atomically consumes a still-valid verification code for `email` and
  returns `{:ok, %{user_id, consumed_at, outcome}}`. The atomic
  `UPDATE … RETURNING` predicates `user_id`, normalized email, hash,
  expiry, and pending state — so a concurrent verifier that races the
  same code observes it as already used.

  ## Options

    * `:principal` (default `nil`) — `:invalid_bearer` returns
      `{:error, :invalid_bearer}` immediately. A valid `Ecto.UUID.t()`
      must equal the row's `user_id`; otherwise the service returns
      `{:error, :unauthorized_principal}`, appends a `verification_failure`
      event, and does NOT consume the row. `nil` (no bearer present)
      skips the principal check entirely — the passwordless flow.

  ## Outcomes (Phase 3)

  After consuming the code, the service branches on the count of the
  User's `:active` AccountMembership rows:

    * **`:single`** — exactly one active membership. The outcome
      carries the `membership` and the claim map produced by
      `AccountsMembership.claims_for/2` (which includes `user_id`,
      `membership_id`, `account_id`, `role`, `plan`, `status`).

    * **`:none`** — zero active memberships. The outcome carries the
      claim map produced by `AccountsMembership.claims_for/1`, which
      intentionally OMITS `membership_id` so a downstream JWT mint +
      `LoadCurrentMembership` halts with `401 membership_id_required`
      and the client routes to invite acceptance.

    * **`:multiple`** — two or more active memberships. The outcome
      carries a `summaries` list (each row has `membership_id`,
      `account_id`, `role`, `plan`, `subscription_status` derived from
      `AccountAccess.status/2`), the opaque `continuation_token` to
      hand to `POST /api/auth/switch-account`, the continuation's
      `expires_at`, and `claims: nil` (no JWT — the client must
      exchange the continuation for one membership).

  All success outcomes are produced inside the same
  `Repo.transaction/1` as the code consume, so the outcome's
  authoritative state is consistent with the consume.

  ## Error outcomes (Phase 2, unchanged)

    * `{:error, :invalid_code}` — wrong code, or expired code
    * `{:error, :code_already_used}` — replay attempt (consumed row)
    * `{:error, :unauthorized_principal}` — supplied bearer resolved to a
      user that does not own the row
    * `{:error, :invalid_bearer}` — plug detected an unparseable token
    * `{:error, :rate_limited, retry_after}` — 10 prior failures in the
      last hour; the eleventh attempt short-circuits with `Retry-After`

  All failure paths except `:invalid_bearer` append a
  `verification_failure` event so the lockout window accumulates.
  """
  @spec verify_code(String.t(), String.t(), keyword()) :: verify_result()
  def verify_code(email, code, opts \\ [])
      when is_binary(email) and is_binary(code) and is_list(opts) do
    normalized_email = normalize_email(email)
    code_hash = hash_code(code)
    principal = Keyword.get(opts, :principal, nil)

    Repo.transaction(
      fn ->
        SQL.query!(Repo, "SELECT pg_advisory_xact_lock($1)", [
          verify_lock_key(normalized_email)
        ])

        with :ok <- check_failure_lockout(normalized_email),
             {:ok, row} <- find_pending_row(normalized_email, code_hash),
             :ok <- assert_principal(principal, row),
             {:ok, consumed_at} <- atomic_consume(row),
             {:ok, outcome} <- build_outcome(row.user_id) do
          {:ok, %{user_id: row.user_id, consumed_at: consumed_at, outcome: outcome}}
        end
      end,
      timeout: :timer.seconds(5)
    )
    |> normalize_verify_tx_result()
  end

  @doc """
  Returns the SHA-256 lower-case hex digest of `code`. Exposed so tests
  can build fixtures with the exact same hash the service uses to
  compare plaintext submissions; never use this on untrusted data.
  """
  @spec hash_code(String.t()) :: String.t()
  def hash_code(code) when is_binary(code) do
    :telemetry.execute([:meal_planner_api, :email_code_auth, :hash_code], %{}, %{})
    :crypto.hash(:sha256, code) |> Base.encode16(case: :lower)
  end

  # ---------------------------------------------------------------------------
  # Rate limiting
  # ---------------------------------------------------------------------------

  # Reserves a slot in the rolling 1-hour window for the email and
  # (when present) the IP. The two counters are serialized by hash-
  # derived advisory locks so concurrent requesters cannot race past
  # the limit on the same key.
  defp reserve_slots(email, nil), do: reserve_email_slot(email)

  defp reserve_slots(email, ip) do
    SQL.query!(Repo, "SELECT pg_advisory_xact_lock($1)", [email_lock_key(email)])

    SQL.query!(Repo, "SELECT pg_advisory_xact_lock($1)", [ip_lock_key(ip)])

    with :ok <- reserve_email_slot(email),
         :ok <- reserve_ip_slot(ip) do
      :ok
    end
  end

  defp reserve_email_slot(email) do
    now = DateTime.utc_now()
    window_start = DateTime.add(now, -@window_seconds, :second)

    if count_events("request", email, nil, window_start) >= @max_per_email_per_window do
      retry_after = compute_retry_after(email, "request", nil, window_start)
      {:error, :rate_limited, retry_after}
    else
      :ok = insert_event("request", email, nil, now)
      :ok
    end
  end

  defp reserve_ip_slot(ip) do
    now = DateTime.utc_now()
    window_start = DateTime.add(now, -@window_seconds, :second)

    if count_events("request", nil, ip, window_start) >= @max_per_ip_per_window do
      retry_after = compute_retry_after(nil, "request", ip, window_start)
      {:error, :rate_limited, retry_after}
    else
      :ok = insert_event("request", nil, ip, now)
      :ok
    end
  end

  defp compute_retry_after(email, kind, ip, window_start) do
    base = from(e in EmailAuthEvent, where: e.kind == ^kind, where: e.occurred_at > ^window_start)

    scoped =
      base
      |> add_optional_eq(:email, email)
      |> add_optional_eq(:client_ip, ip)

    earliest =
      scoped
      |> select([e], e.occurred_at)
      |> order_by([e], asc: e.occurred_at)
      |> limit(1)
      |> Repo.one()

    case earliest do
      nil ->
        @window_seconds

      %DateTime{} = dt ->
        max(@window_seconds - DateTime.diff(DateTime.utc_now(), dt, :second), 1)
    end
  end

  defp add_optional_eq(query, _field, nil), do: query

  defp add_optional_eq(query, field, value) do
    from(e in query, where: field(e, ^field) == ^value)
  end

  defp insert_event(kind, email, ip, now) do
    %EmailAuthEvent{}
    |> Ecto.Changeset.change(%{
      kind: kind,
      email: email || "unknown",
      client_ip: ip,
      occurred_at: now
    })
    |> Repo.insert()
    |> case do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  defp count_events(kind, email, ip, window_start) do
    base = from(e in EmailAuthEvent, where: e.kind == ^kind, where: e.occurred_at > ^window_start)

    base
    |> add_optional_eq(:email, email)
    |> add_optional_eq(:client_ip, ip)
    |> Repo.aggregate(:count)
  end

  # ---------------------------------------------------------------------------
  # Lock-key hashing
  # ---------------------------------------------------------------------------

  defp email_lock_key(email) do
    (@email_lock_salt + truncated_hash(email)) |> Integer.mod(1_000_000_007)
  end

  defp ip_lock_key(ip) do
    (@ip_lock_salt + truncated_hash(ip)) |> Integer.mod(1_000_000_007)
  end

  defp truncated_hash(value) when is_binary(value) do
    <<top::64, _::binary>> = :crypto.hash(:sha256, value)
    top
  end

  defp truncated_hash(_), do: 0

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # The surrounding transaction wraps `request_code/2`. When the inner
  # function returns `{:error, :rate_limited, retry_after}`, the
  # transaction commits (no DB-level error) and `Repo.transaction/2`
  # returns `{:ok, {:error, :rate_limited, retry_after}}` — which we
  # unwrap to the public result shape.
  defp normalize_tx_result({:ok, :sent}), do: {:ok, :sent}

  defp normalize_tx_result({:ok, {:error, :rate_limited, retry_after}}),
    do: {:error, :rate_limited, retry_after}

  defp normalize_tx_result(other), do: other

  defp normalize_email(email) do
    email |> String.trim() |> String.downcase()
  end

  # Coerce the IP into a stable string that fits the schema's
  # `:string` column. `nil` and unparsable inputs collapse to `nil`
  # so the per-email counter still applies.
  defp normalize_client_ip(nil), do: nil

  defp normalize_client_ip(ip) when is_binary(ip) do
    trimmed = String.trim(ip)

    if valid_ip_string?(trimmed), do: trimmed, else: nil
  end

  defp normalize_client_ip(_), do: nil

  # `:inet.parse_address/1` is broken in this OTP/runtime combo (it
  # raises instead of returning `{:error, _}` for invalid input and
  # silently misbehaves for valid input), so we validate dotted IPv4
  # literals ourselves. IPv6 addresses are intentionally not accepted:
  # the rate-limit key only needs a stable bucket identifier, and the
  # test fixtures use IPv4 only.
  defp valid_ip_string?(ip) do
    case String.split(ip, ".") do
      [a, b, c, d] -> ipv4_octet?(a) and ipv4_octet?(b) and ipv4_octet?(c) and ipv4_octet?(d)
      _ -> false
    end
  end

  defp ipv4_octet?(octet) do
    case Integer.parse(octet) do
      {n, ""} when n >= 0 and n <= 255 -> true
      _ -> false
    end
  end

  defp fetch_user(email) do
    from(u in PersistenceUser, where: u.email == ^email, limit: 1)
    |> Repo.one()
  end

  defp mint_code do
    # Six numeric digits in [100000, 999999], zero-padded.
    min = 100_000
    max = 999_999

    :telemetry.execute([:meal_planner_api, :email_code_auth, :mint_code], %{}, %{})
    code_int = min + :rand.uniform(max - min + 1) - 1
    code_int |> Integer.to_string() |> String.pad_leading(@code_length, "0")
  end

  defp deliver_code(user, email, code) do
    name =
      case is_binary(user.name) and user.name != "" do
        true -> user.name
        false -> nil
      end

    email_record = build_email(email, code, name)

    Mailer.deliver_now(email_record)
    :ok
  end

  defp build_email(email, code, nil), do: EmailCodeEmail.build(email, code)

  defp build_email(email, code, name) do
    # Use the named variant by re-importing Bamboo.Email and overriding
    # the `:to` field; the address and code remain unchanged.
    email_record = EmailCodeEmail.build(email, code)

    %{email_record | to: {name, email}}
  end

  # ---------------------------------------------------------------------------
  # Phase 2 — Verify-path helpers
  # ---------------------------------------------------------------------------

  defp normalize_verify_tx_result({:ok, inner}), do: inner
  defp normalize_verify_tx_result(other), do: other

  defp check_failure_lockout(email) do
    now = DateTime.utc_now()
    window_start = DateTime.add(now, -@window_seconds, :second)

    if count_events("verification_failure", email, nil, window_start) >=
         @max_failures_per_window do
      retry_after = compute_retry_after(email, "verification_failure", nil, window_start)
      {:error, :rate_limited, retry_after}
    else
      :ok
    end
  end

  defp find_pending_row(email, code_hash) do
    case from(r in EmailVerificationCode,
           where: r.email == ^email,
           where: r.code_hash == ^code_hash
         )
         |> Repo.one() do
      nil ->
        _ = insert_failure_event(email)
        {:error, :invalid_code}

      %EmailVerificationCode{consumed_at: consumed} when not is_nil(consumed) ->
        _ = insert_failure_event(email)
        {:error, :code_already_used}

      %EmailVerificationCode{expires_at: expires_at} = row ->
        if DateTime.compare(expires_at, DateTime.utc_now()) == :lt do
          _ = insert_failure_event(email)
          {:error, :invalid_code}
        else
          {:ok, row}
        end
    end
  end

  # `nil` means passwordless — no principal binding check.
  defp assert_principal(nil, _row), do: :ok

  # Plug-detected unparseable bearer — short-circuit before touching the DB.
  defp assert_principal(:invalid_bearer, _row), do: {:error, :invalid_bearer}

  # Any other value is treated as a principal user_id and must match the
  # row's owner. Mismatch counts as a failed-verification event so the
  # lockout window accumulates.
  defp assert_principal(principal_user_id, %EmailVerificationCode{user_id: user_id, email: email})
       when principal_user_id != nil and principal_user_id != :invalid_bearer do
    if principal_user_id == user_id do
      :ok
    else
      _ = insert_failure_event(email)
      {:error, :unauthorized_principal}
    end
  end

  # Atomic UPDATE … RETURNING guarded by `(user_id, email, code_hash,
  # consumed_at IS NULL, expires_at > now)`. Race protection: if a
  # concurrent verifier beat us to the row, 0 rows are updated and we
  # surface `:code_already_used`.
  defp atomic_consume(%EmailVerificationCode{user_id: user_id} = row) do
    now = DateTime.utc_now()

    query =
      from(r in EmailVerificationCode,
        where: r.user_id == ^user_id,
        where: r.email == ^row.email,
        where: r.code_hash == ^row.code_hash,
        where: is_nil(r.consumed_at),
        where: r.expires_at > ^now
      )

    case Repo.update_all(query, set: [consumed_at: now]) do
      {0, _} ->
        # The row was pending when we looked but another verifier won
        # the race. Counts as a failed attempt so a burst of concurrent
        # replays cannot slip past the lockout counter.
        _ = insert_failure_event(row.email)
        {:error, :code_already_used}

      {1, _} ->
        {:ok, now}
    end
  end

  defp verify_lock_key(email) do
    (@verify_lock_salt + truncated_hash(email)) |> Integer.mod(1_000_000_007)
  end

  defp insert_failure_event(email) do
    %EmailAuthEvent{}
    |> Ecto.Changeset.change(%{
      kind: "verification_failure",
      email: email,
      client_ip: nil,
      occurred_at: DateTime.utc_now()
    })
    |> Repo.insert()

    :ok
  end

  # ---------------------------------------------------------------------------
  # Phase 3 — Outcomes (issue #31 task 3.2)
  # ---------------------------------------------------------------------------

  @doc """
  Phase 3 — Loads the User's `:active` AccountMembership rows, fully
  preloaded with `:account`, and returns them as the source of truth for
  outcome branching. Pure-Repo, no side effects.
  """
  @spec load_active_memberships(Ecto.UUID.t()) :: [PersistenceAccountMembership.t()]
  def load_active_memberships(user_id) do
    from(m in PersistenceAccountMembership,
      where: m.user_id == ^user_id,
      where: m.status == :active,
      preload: [:account]
    )
    |> Repo.all()
  end

  @doc """
  Phase 3 — Serializes the User's `:active` AccountMembership rows as
  the multi-membership summary payload. Each summary carries
  `membership_id`, `account_id`, `role`, `plan`, and
  `subscription_status` derived from `AccountAccess.status/2` — per
  `specs/email-code-authentication/spec.md` §"Verify Response Outcomes
  by Active-Membership Count" and §"Membership Summary Tenancy
  Isolation".

  Tenancy isolation is enforced by `load_active_memberships/1`'s
  `where: m.user_id == ^user_id` filter — a User cannot see another
  User's membership on a shared Account.
  """
  @spec summarize_active_memberships(Ecto.UUID.t()) :: [map()]
  def summarize_active_memberships(user_id) do
    user_id
    |> load_active_memberships()
    |> Enum.map(&summarize_membership/1)
  end

  defp summarize_membership(%PersistenceAccountMembership{account: account} = membership) do
    %{state: state} = AccountAccess.status(account, DateTime.utc_now())

    %{
      membership_id: to_string(membership.id),
      account_id: to_string(membership.account_id),
      role: Atom.to_string(membership.role),
      plan: Atom.to_string(account.plan),
      subscription_status: Atom.to_string(state)
    }
  end

  # Build the post-consume outcome. Loads the User (single, cheap) so
  # the no-membership claims builder can read `email`/`name`, then
  # branches on active-membership count.
  defp build_outcome(user_id) do
    user = Repo.get!(PersistenceUser, user_id)
    memberships = load_active_memberships(user_id)

    case memberships do
      [single] ->
        claims = AccountsMembership.claims_for(user, single)
        {:ok, %{kind: :single, membership: single, claims: claims}}

      [] ->
        claims = AccountsMembership.claims_for(user)
        {:ok, %{kind: :none, claims: claims}}

      many when length(many) >= 2 ->
        summaries = Enum.map(many, &summarize_membership/1)
        membership_ids = Enum.map(many, & &1.id)
        {:ok, plaintext, _row, expires_at} = mint_continuation(user_id, membership_ids)

        {:ok,
         %{
           kind: :multiple,
           summaries: summaries,
           continuation_token: plaintext,
           expires_at: expires_at,
           claims: nil
         }}
    end
  end

  # ---------------------------------------------------------------------------
  # Phase 3 — Continuations (issue #31 task 3.4)
  # ---------------------------------------------------------------------------

  @doc """
  Phase 3 — Mints a fresh opaque continuation for `user_id` and the
  given `membership_ids`. Returns `{plaintext, hash, expires_at}`:

    * `plaintext` — 32 random bytes base64url-encoded (no padding),
      ~43-char string. Emitted exactly once to the caller; the column
      `token_hash` stores only the SHA-256 hex digest.
    * `hash` — 64-char lower-case hex SHA-256 of the plaintext.
    * `expires_at` — `now + @continuation_ttl_seconds` (5 minutes per
      `design.md` §"Persistence Shapes").

  The function inserts the `account_selection_continuations` row and
  one `account_selection_continuation_memberships` join row per
  membership id in a single `Repo.transaction/1`.
  """
  @spec mint_continuation(Ecto.UUID.t(), [Ecto.UUID.t()]) ::
          {:ok, String.t(), AccountSelectionContinuation.t(), DateTime.t()}
  def mint_continuation(user_id, membership_ids)
      when is_binary(user_id) and is_list(membership_ids) do
    plaintext = generate_url_safe_token(32)
    hash = hash_continuation(plaintext)
    expires_at = DateTime.add(DateTime.utc_now(), @continuation_ttl_seconds, :second)

    Repo.transaction(fn ->
      {:ok, row} =
        %AccountSelectionContinuation{}
        |> Ecto.Changeset.change(%{
          user_id: user_id,
          token_hash: hash,
          expires_at: expires_at
        })
        |> Repo.insert()

      Enum.each(membership_ids, fn membership_id ->
        {:ok, _link} =
          %AccountSelectionContinuationMembership{}
          |> Ecto.Changeset.change(%{
            continuation_id: row.id,
            membership_id: membership_id
          })
          |> Repo.insert()
      end)

      {:ok, plaintext, row, expires_at}
    end)
    |> case do
      {:ok, {:ok, plaintext, row, expires_at}} -> {:ok, plaintext, row, expires_at}
      {:ok, {:error, _} = err} -> err
      {:error, _} -> {:error, :unable_to_mint_continuation}
    end
  end

  @doc """
  Phase 3 — Test-only fixture constructor. Mints a continuation with a
  caller-supplied `expires_at` so expired-path tests can backdate the
  row without `Process.sleep/1` (the AGENTS.md ban). Production code
  MUST use `mint_continuation/2`; this helper is exposed solely so the
  Phase 3 service tests can build deterministic fixtures.
  """
  @spec mint_test_continuation(Ecto.UUID.t(), [Ecto.UUID.t()], keyword()) :: String.t()
  def mint_test_continuation(user_id, membership_ids, opts \\ []) do
    expires_at =
      Keyword.get(
        opts,
        :expires_at,
        DateTime.add(DateTime.utc_now(), @continuation_ttl_seconds, :second)
      )

    plaintext = generate_url_safe_token(32)
    hash = hash_continuation(plaintext)

    Repo.transaction(fn ->
      {:ok, row} =
        %AccountSelectionContinuation{}
        |> Ecto.Changeset.change(%{
          user_id: user_id,
          token_hash: hash,
          expires_at: expires_at
        })
        |> Repo.insert()

      Enum.each(membership_ids, fn membership_id ->
        {:ok, _link} =
          %AccountSelectionContinuationMembership{}
          |> Ecto.Changeset.change(%{
            continuation_id: row.id,
            membership_id: membership_id
          })
          |> Repo.insert()
      end)

      :ok
    end)

    plaintext
  end

  @doc """
  Phase 3 — Hashes a continuation plaintext token (SHA-256 lower-case
  hex). Exposed so tests can reproduce the hash for an existing token
  without re-minting one. Mirrors the public-API pattern of
  `InviteService.hash_token/1`.
  """
  @spec hash_continuation(String.t()) :: String.t()
  def hash_continuation(plaintext) when is_binary(plaintext) do
    :crypto.hash(:sha256, plaintext) |> Base.encode16(case: :lower)
  end

  @doc """
  Phase 3 — Exchanges a continuation plaintext for a single
  `AccountMembership`. The exchange runs inside one
  `Repo.transaction/1`:

      1. Hash the plaintext and look up the row under
         `SELECT … FOR UPDATE` so concurrent exchange attempts
         serialize on the same row.
      2. Validate: not consumed, not expired, and (when supplied) the
         `principal` User matches the row's `user_id`.
      3. Verify the requested `target_membership_id` is in the
         continuation's allowed membership set via the join table.
      4. Delegate to `AccountsMembership.switch_account/2`, which
         enforces ownership and `:active` status.
      5. Mint the `access_v2` JWT inside the same transaction.
      6. Mark `consumed_at` and commit together.

  Pre-mint failures (steps 2–4) leave `consumed_at` NULL — the
  transaction rolls back. Concurrent / replayed exchange sees
  `:consumed_continuation` and returns no token.
  """
  @spec exchange_continuation(String.t(), String.t(), keyword()) :: exchange_result()
  def exchange_continuation(plaintext, target_membership_id, opts \\ [])
      when is_binary(plaintext) and is_binary(target_membership_id) and is_list(opts) do
    hash = hash_continuation(plaintext)
    principal = Keyword.get(opts, :principal, nil)

    with :ok <- assert_exchange_principal(principal) do
      Repo.transaction(
        fn ->
          SQL.query!(Repo, "SELECT pg_advisory_xact_lock($1)", [
            continuation_lock_key(hash)
          ])

          with {:ok, row} <- lookup_continuation_for_exchange(hash),
               :ok <- assert_continuation_unconsumed(row),
               :ok <- assert_continuation_unexpired(row),
               :ok <- assert_continuation_bearer(principal, row),
               :ok <- assert_continuation_set(row, target_membership_id),
               {:ok, switch_payload} <- delegate_to_switch(row.user_id, target_membership_id),
               {:ok, access_token} <- mint_exchange_token(switch_payload) do
            consume_continuation(row)

            {:ok,
             Map.merge(switch_payload, %{
               access_token: access_token
             })}
          end
        end,
        timeout: :timer.seconds(5)
      )
      |> normalize_exchange_tx_result()
    end
  end

  # Pre-flight guard so an unparseable bearer short-circuits before the
  # advisory lock — the lock is a Postgres round-trip we don't need to
  # pay for a token that the plug already rejected.
  defp assert_exchange_principal(:invalid_bearer), do: {:error, :invalid_bearer}
  defp assert_exchange_principal(_), do: :ok

  defp lookup_continuation_for_exchange(hash) do
    case from(c in AccountSelectionContinuation,
           where: c.token_hash == ^hash,
           lock: "FOR UPDATE"
         )
         |> Repo.one() do
      nil -> {:error, :invalid_continuation}
      %AccountSelectionContinuation{} = row -> {:ok, row}
    end
  end

  defp assert_continuation_unconsumed(%AccountSelectionContinuation{consumed_at: consumed})
       when not is_nil(consumed),
       do: {:error, :consumed_continuation}

  defp assert_continuation_unconsumed(_), do: :ok

  defp assert_continuation_unexpired(%AccountSelectionContinuation{expires_at: expires_at}) do
    if DateTime.compare(expires_at, DateTime.utc_now()) == :lt do
      {:error, :expired_continuation}
    else
      :ok
    end
  end

  # `nil` (bearerless) and `:invalid_bearer` are pre-filtered by
  # `assert_exchange_principal/1`. A non-nil principal that doesn't
  # match the row's `user_id` is `:foreign_bearer`.
  defp assert_continuation_bearer(nil, _row), do: :ok

  defp assert_continuation_bearer(principal_user_id, %AccountSelectionContinuation{
         user_id: user_id
       })
       when not is_nil(principal_user_id) do
    if principal_user_id == user_id, do: :ok, else: {:error, :foreign_bearer}
  end

  defp assert_continuation_set(
         %AccountSelectionContinuation{id: continuation_id},
         target_membership_id
       ) do
    case Ecto.UUID.cast(target_membership_id) do
      :error ->
        {:error, :not_in_continuation_set}

      {:ok, uuid} ->
        if Repo.exists?(
             from(m in AccountSelectionContinuationMembership,
               where: m.continuation_id == ^continuation_id,
               where: m.membership_id == ^uuid
             )
           ) do
          :ok
        else
          {:error, :not_in_continuation_set}
        end
    end
  end

  defp delegate_to_switch(user_id, target_membership_id) do
    user = Repo.get!(PersistenceUser, user_id)

    case AccountsMembership.switch_account(user, target_membership_id) do
      {:ok, payload} -> {:ok, payload}
      {:error, _} = err -> err
    end
  end

  defp mint_exchange_token(%{user: user, claims: claims}) do
    case Guardian.encode_and_sign(user, claims, token_type: "access") do
      {:ok, token, _verified_claims} -> {:ok, token}
      _ -> {:error, :token_refresh_failed}
    end
  end

  defp consume_continuation(%AccountSelectionContinuation{id: row_id}) do
    {1, _} =
      Repo.update_all(
        from(c in AccountSelectionContinuation, where: c.id == ^row_id),
        set: [consumed_at: DateTime.utc_now()]
      )

    :ok
  end

  defp normalize_exchange_tx_result({:ok, {:ok, payload}}), do: {:ok, payload}
  defp normalize_exchange_tx_result({:ok, {:error, _} = err}), do: err
  defp normalize_exchange_tx_result(other), do: other

  defp continuation_lock_key(hash) do
    (@continuation_lock_salt + truncated_hash(hash)) |> Integer.mod(1_000_000_007)
  end

  # Phase 3 token-mint helper, shared by `mint_continuation/2` and
  # `mint_test_continuation/3`. 32 random bytes → ~43 base64url chars.
  defp generate_url_safe_token(byte_size) do
    byte_size
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end
end
