defmodule MealPlannerApi.PlanningAgent.SessionTest do
  @moduledoc """
  Seam 1 of spec #93: the planning agent session module, driven by the
  scripted model adapter and fakes.
  """

  use ExUnit.Case, async: false

  import Ecto.Query
  import ExUnit.CaptureLog
  import MealPlannerApi.PlanningAgentFixtures

  alias MealPlannerApi.Data.PlanningRepo
  alias MealPlannerApi.Persistence.Planning.PlanningSession
  alias MealPlannerApi.PlanningAgent.Model.{OpenAIResponses, Scripted}
  alias MealPlannerApi.PlanningAgent.Session
  alias MealPlannerApi.Repo

  @monday ~D[2026-11-02]
  @tuesday ~D[2026-11-03]

  setup do
    sandbox_sessions!()
    :ok = MealPlannerApi.SubscriptionPlanFixtures.ensure_plans!()

    household = household!()
    %{household: household, owner: household.owner}
  end

  defp start!(household, member, script, opts \\ []) do
    attrs = session_attrs(household, member, Keyword.get(opts, :range, {@monday, @tuesday}))

    session_opts =
      Keyword.merge(
        [model: {Scripted, script: script, notify: self()}, subscriber: self()],
        Keyword.drop(opts, [:range])
      )

    {:ok, %{session_id: session_id, pid: pid}} = Session.start(attrs, session_opts)
    {session_id, pid}
  end

  defp active_sessions(household) do
    Repo.all(
      from(s in PlanningSession,
        where: s.account_id == ^household.account_id and s.status == :active
      )
    )
  end

  describe "starting a Planning Session" do
    test "a Member opens a Planning Session for a Planning Range", %{household: h, owner: owner} do
      {session_id, _pid} = start!(h, owner, [])

      assert [%PlanningSession{id: ^session_id} = row] = active_sessions(h)
      assert row.range_from == @monday
      assert row.range_to == @tuesday
      assert row.lock_owner_membership_id == owner.membership_id
    end

    test "a second Member of the same Household is told one is already active",
         %{household: h, owner: owner} do
      _ = start!(h, owner, [])
      other = member!(h)

      # A disjoint range is still refused: one Planning Session per Household.
      attrs = session_attrs(h, other, {~D[2026-12-01], ~D[2026-12-02]})

      assert {:error, :session_already_active} =
               Session.start(attrs, model: {Scripted, []}, subscriber: self())

      assert length(active_sessions(h)) == 1
    end

    test "a Planning Range must cover only unplanned days", %{household: h, owner: owner} do
      recipe = recipe!("Fictitious stew", [ingredient!("Fictitious lentil")])
      scheduled_meal!(h, @tuesday, :lunch, recipe)

      assert {:error, :range_already_planned} =
               Session.start(session_attrs(h, owner, {@monday, @tuesday}),
                 model: {Scripted, []},
                 subscriber: self()
               )

      assert active_sessions(h) == []
    end

    test "an inverted range is rejected", %{household: h, owner: owner} do
      assert {:error, :invalid_range} =
               Session.start(session_attrs(h, owner, {@tuesday, @monday}),
                 model: {Scripted, []},
                 subscriber: self()
               )
    end

    test "a model adapter that refuses to initialise leaves no session behind",
         %{household: h, owner: owner} do
      defmodule RefusingModel do
        @behaviour MealPlannerApi.PlanningAgent.Model
        def init(_opts), do: {:error, :spend_caps_unconfigured}
        def respond(state, _request), do: {:error, :unreachable, state}
      end

      assert {:error, :spend_caps_unconfigured} =
               Session.start(session_attrs(h, owner, {@monday, @tuesday}),
                 model: {RefusingModel, []},
                 subscriber: self()
               )

      assert active_sessions(h) == []
    end
  end

  describe "consent" do
    test "without recorded consent the session refuses to call the model",
         %{household: h, owner: owner} do
      {session_id, pid} = start!(h, owner, [{:text, "should never be produced"}])

      assert {:error, :consent_required} = Session.send_message(pid, "Plan something light")

      assert_receive {:planning_agent_event, ^session_id, %{"type" => "consent_required"}}
      refute_receive {:scripted_model_request, _}, 100
    end

    test "after the Member gives consent the model is called", %{household: h, owner: owner} do
      {session_id, pid} = start!(h, owner, [{:text, "Hello, let's plan."}])

      assert :ok = Session.record_consent(pid)
      assert :ok = Session.send_message(pid, "Plan something light")

      assert_receive {:scripted_model_request, _request}

      assert_receive {:planning_agent_event, ^session_id,
                      %{"type" => "assistant_message", "text" => "Hello, let's plan."}}

      assert_receive {:planning_agent_event, ^session_id, %{"type" => "turn_completed"}}
    end

    test "a message over the size limit is refused before it reaches the model",
         %{household: h, owner: owner} do
      consent!(h, owner)
      {_session_id, pid} = start!(h, owner, [{:text, "should never be produced"}])
      too_long = String.duplicate("a", Session.max_message_bytes() + 1)

      assert {:error, :message_too_long} = Session.send_message(pid, too_long)

      assert :sys.get_state(pid).messages == []
      refute_receive {:scripted_model_request, _}, 100
    end

    test "consent recorded earlier is injected at start", %{household: h, owner: owner} do
      consent!(h, owner)
      {session_id, pid} = start!(h, owner, [{:text, "Ready."}])

      assert :ok = Session.send_message(pid, "Hi")
      assert_receive {:planning_agent_event, ^session_id, %{"type" => "turn_completed"}}
    end
  end

  describe "household context" do
    test "profile, settings and Restrictions are injected by code at start without naming Members",
         %{household: h, owner: owner} do
      other = member!(h)
      diet!(other, :vegetarian)
      peanut = ingredient!("Fictitious peanut", [:peanut])
      allergy!(owner, peanut)
      {:ok, _} = MealPlannerApi.NutritionGoals.put(h.account_id, nutrition_goal())
      consent!(h, owner)

      {session_id, pid} = start!(h, owner, [{:text, "ok"}])
      :ok = Session.send_message(pid, "Hi")

      assert_receive {:scripted_model_request, %{instructions: instructions}}
      assert instructions =~ "2026-11-02"
      assert instructions =~ "contains_meat"
      assert instructions =~ "peanut"
      assert instructions =~ "1800"
      refute instructions =~ other.user_id
      refute instructions =~ owner.user_id
      assert_receive {:planning_agent_event, ^session_id, %{"type" => "turn_completed"}}
    end
  end

  describe "limits and failures" do
    test "the loop stops after the iteration limit", %{household: h, owner: owner} do
      consent!(h, owner)
      ask_forever = fn _request -> {:tool_calls, [{"search_recipes", %{"query" => "x"}}]} end

      {session_id, pid} = start!(h, owner, List.duplicate(ask_forever, 20), max_iterations: 3)
      :ok = Session.send_message(pid, "Plan")

      assert_receive {:planning_agent_event, ^session_id,
                      %{"type" => "limit_reached", "limit" => "iterations"}},
                     2_000

      for _ <- 1..3, do: assert_receive({:scripted_model_request, _})
      refute_receive {:scripted_model_request, _}, 100
    end

    test "the loop stops at the global deadline", %{household: h, owner: owner} do
      consent!(h, owner)
      slow = fn _request -> Process.sleep(500) && {:text, "late"} end

      {session_id, pid} = start!(h, owner, [slow], deadline_ms: 50)
      :ok = Session.send_message(pid, "Plan")

      assert_receive {:planning_agent_event, ^session_id,
                      %{"type" => "limit_reached", "limit" => "time"}},
                     1_000

      refute_receive {:planning_agent_event, ^session_id, %{"type" => "assistant_message"}}, 700
    end

    test "spend reserved by a turn killed at the deadline stays counted",
         %{household: h, owner: owner} do
      consent!(h, owner)

      # The provider never answers, so every turn is killed at the deadline.
      # One worst-case reservation (~400_000 micro-USD) fits the cap; two do not.
      model_opts = [
        api_key: "test-key",
        spend_cap_micros: 600_000,
        token_cap: 100_000_000,
        input_price_micros_per_mtok: 1_000_000,
        output_price_micros_per_mtok: 4_000_000,
        max_output_tokens: 100_000,
        req_options: [plug: fn _conn -> Process.sleep(:infinity) end]
      ]

      {session_id, pid} =
        start!(h, owner, [], model: {OpenAIResponses, model_opts}, deadline_ms: 100)

      :ok = Session.send_message(pid, "Plan")

      assert_receive {:planning_agent_event, ^session_id,
                      %{"type" => "limit_reached", "limit" => "time"}},
                     1_000

      # Continuing past the time limit needs the Member's authorization; the
      # spend cap is never extended by it.
      :ok = Session.authorize_continuation(pid, owner.membership_id)

      assert_receive {:planning_agent_event, ^session_id,
                      %{"type" => "agent_unavailable", "reason" => "spend_cap_reached"}},
                     1_000
    end

    test "spend and token caps bound the whole Planning Session, not one request",
         %{household: h, owner: owner} do
      consent!(h, owner)

      # The first answer reports usage just under the token cap, so the
      # second Member message cannot reserve its worst case: the cap is not
      # reset per request. A new Planning Session starts with a fresh ledger.
      answer = %{
        "output" => [
          %{"type" => "message", "content" => [%{"type" => "output_text", "text" => "Hello"}]}
        ],
        "usage" => %{"input_tokens" => 999_000, "output_tokens" => 0}
      }

      model_opts = [
        api_key: "test-key",
        spend_cap_micros: 100_000_000,
        token_cap: 1_000_000,
        input_price_micros_per_mtok: 1,
        output_price_micros_per_mtok: 1,
        max_output_tokens: 1_000,
        req_options: [plug: fn conn -> Req.Test.json(conn, answer) end]
      ]

      {session_id, pid} = start!(h, owner, [], model: {OpenAIResponses, model_opts})

      :ok = Session.send_message(pid, "Plan")

      assert_receive {:planning_agent_event, ^session_id,
                      %{"type" => "assistant_message", "text" => "Hello"}}

      assert_receive {:planning_agent_event, ^session_id, %{"type" => "turn_completed"}}

      :ok = Session.send_message(pid, "Plan again")

      assert_receive {:planning_agent_event, ^session_id,
                      %{"type" => "agent_unavailable", "reason" => "token_cap_reached"}}

      :ok = Session.cancel(pid, %{membership_id: owner.membership_id, owner?: true})

      {next_session_id, next_pid} = start!(h, owner, [], model: {OpenAIResponses, model_opts})
      :ok = Session.send_message(next_pid, "Plan")

      assert_receive {:planning_agent_event, ^next_session_id,
                      %{"type" => "assistant_message", "text" => "Hello"}}
    end

    test "a provider failure tells the Member planning is not possible now",
         %{household: h, owner: owner} do
      consent!(h, owner)
      # Transient failures are retried first (see SessionBoundsTest); a
      # permission failure is reported at once.
      {session_id, pid} = start!(h, owner, [{:error, :provider_unauthorized}])
      :ok = Session.send_message(pid, "Plan")

      assert_receive {:planning_agent_event, ^session_id,
                      %{"type" => "agent_unavailable", "reason" => "provider_unauthorized"}}
    end
  end

  describe "cancel" do
    test "the session's Member cancels and the Household slot is released",
         %{household: h, owner: owner} do
      member = member!(h)
      {session_id, pid} = start!(h, member, [])
      ref = Process.monitor(pid)

      assert :ok = Session.cancel(pid, %{membership_id: member.membership_id, owner?: false})
      assert_receive {:planning_agent_event, ^session_id, %{"type" => "session_cancelled"}}
      assert_receive {:DOWN, ^ref, :process, ^pid, _}
      assert active_sessions(h) == []

      assert {:ok, _} =
               Session.start(session_attrs(h, owner, {@monday, @tuesday}),
                 model: {Scripted, []},
                 subscriber: self()
               )
    end

    test "the Owner may cancel another Member's session; a peer may not",
         %{household: h, owner: owner} do
      member = member!(h)
      peer = member!(h)
      {_session_id, pid} = start!(h, member, [])

      assert {:error, :forbidden} =
               Session.cancel(pid, %{membership_id: peer.membership_id, owner?: false})

      assert Session.whereis(h.account_id) == pid
      assert :ok = Session.cancel(pid, %{membership_id: owner.membership_id, owner?: true})
    end

    test "a cancel the store refuses still expires the session and frees the Household",
         %{household: h, owner: owner} do
      member = member!(h)
      other = member!(h)
      {session_id, pid} = start!(h, member, [])
      ref = Process.monitor(pid)

      # The stored lock owner no longer matches, so cancel_session refuses.
      Repo.update_all(from(s in PlanningSession, where: s.id == ^session_id),
        set: [lock_owner_membership_id: other.membership_id]
      )

      assert :ok = Session.cancel(pid, %{membership_id: member.membership_id, owner?: false})
      assert_receive {:DOWN, ^ref, :process, ^pid, _}

      assert %PlanningSession{status: :expired} = Repo.get!(PlanningSession, session_id)

      assert {:ok, _} =
               Session.start(session_attrs(h, owner, {@monday, @tuesday}),
                 model: {Scripted, []},
                 subscriber: self()
               )
    end
  end

  describe "shutdown and lease" do
    # A shutdown is a server restart: the session stays recoverable for its
    # grace (see SessionRecoveryTest), so its row and slot are kept.
    test "a supervisor shutdown keeps the Household lock for recovery",
         %{household: h, owner: owner} do
      {session_id, pid} = start!(h, owner, [])
      ref = Process.monitor(pid)

      assert :ok =
               DynamicSupervisor.terminate_child(
                 MealPlannerApi.PlanningAgent.SessionSupervisor,
                 pid
               )

      assert_receive {:DOWN, ^ref, :process, ^pid, _}
      refute_received {:planning_agent_event, ^session_id, %{"type" => "session_ended"}}
      assert [%PlanningSession{id: ^session_id}] = active_sessions(h)
    end

    test "a session whose lock row was expired stops on lease renewal",
         %{household: h, owner: owner} do
      {session_id, pid} = start!(h, owner, [])
      ref = Process.monitor(pid)

      assert {:ok, _} = PlanningRepo.expire_session(h.account_id, session_id)
      send(pid, :renew_lease)

      assert_receive {:DOWN, ^ref, :process, ^pid, _}
      assert_receive {:planning_agent_event, ^session_id, %{"type" => "session_ended"}}
      assert %PlanningSession{status: :expired} = Repo.get!(PlanningSession, session_id)
    end

    test "a start while the old session is still registered is refused with a typed error",
         %{household: h, owner: owner} do
      # The old row was expired behind its live process (a lapsed lease), so
      # the database lock is free while the process is still registered
      # until its next lease renewal.
      {old_session_id, old_pid} = start!(h, owner, [])
      assert {:ok, _} = PlanningRepo.expire_session(h.account_id, old_session_id)
      other = member!(h)

      log =
        capture_log(fn ->
          assert {:error, :session_already_active} =
                   Session.start(session_attrs(h, other, {@monday, @tuesday}),
                     model: {Scripted, []},
                     subscriber: self()
                   )
        end)

      refute log =~ "MatchError"
      assert Session.whereis(h.account_id) == old_pid
      # The refused start released the row it had just taken.
      assert active_sessions(h) == []
    end
  end

  describe "secrets in process state" do
    @secret "sk-test-secret"

    setup do
      # Print states and stacktraces in full, so a truncated report cannot
      # hide the secret and make the assertion pass for the wrong reason.
      previous = Application.get_env(:logger, :translator_inspect_opts)
      Application.put_env(:logger, :translator_inspect_opts, limit: :infinity)
      on_exit(fn -> Application.put_env(:logger, :translator_inspect_opts, previous || []) end)
    end

    defp start_with_secret!(household, member) do
      model_opts = [
        api_key: @secret,
        spend_cap_micros: 1_000,
        token_cap: 1_000,
        input_price_micros_per_mtok: 1,
        output_price_micros_per_mtok: 1
      ]

      start!(household, member, [], model: {OpenAIResponses, model_opts})
    end

    test "the provider API key is absent from the session's status output",
         %{household: h, owner: owner} do
      {_session_id, pid} = start_with_secret!(h, owner)

      status = inspect(:sys.get_status(pid), limit: :infinity, printable_limit: :infinity)

      assert status =~ "model_state"
      refute status =~ @secret

      :ok = Session.cancel(pid, %{membership_id: owner.membership_id, owner?: true})
    end

    test "the provider API key is absent from a crashed session's report",
         %{household: h, owner: owner} do
      {_session_id, pid} = start_with_secret!(h, owner)
      ref = Process.monitor(pid)

      log =
        capture_log(fn ->
          # No handle_call clause matches, so the session crashes with its
          # state in the stacktrace arguments.
          catch_exit(GenServer.call(pid, {:cancel, :not_an_actor}))
          assert_receive {:DOWN, ^ref, :process, ^pid, _}
          Process.sleep(50)
        end)

      assert log =~ "handle_call"
      refute log =~ @secret
    end
  end

  defp nutrition_goal do
    %{
      "calories" => %{"min" => 1800, "max" => 2200},
      "protein_g" => %{"min" => 60, "max" => 120},
      "carbs_g" => %{"min" => 150, "max" => 300},
      "fat_g" => %{"min" => 40, "max" => 80}
    }
  end
end
