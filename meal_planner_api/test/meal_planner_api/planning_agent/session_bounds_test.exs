defmodule MealPlannerApi.PlanningAgent.SessionBoundsTest do
  @moduledoc """
  Execution bounds of the planning agent session (#108, spec #93): per-call
  deadlines and retry budgets, observed through the session module with the
  scripted model, a fake recipe search and a fake optimizer.
  """

  use ExUnit.Case, async: false

  import MealPlannerApi.PlanningAgentFixtures

  alias MealPlannerApi.PlanningAgent.{FakeOptimizer, FakeRecipeSearch}
  alias MealPlannerApi.PlanningAgent.Model.Scripted
  alias MealPlannerApi.PlanningAgent.Session

  @monday ~D[2026-11-02]
  @tuesday ~D[2026-11-03]

  # Short per-call deadlines and backoff so every bound is observable fast.
  @fast %{
    model: %{timeout_ms: 100, backoff_ms: 1},
    solver: %{timeout_ms: 100},
    read: %{timeout_ms: 100, backoff_ms: 1}
  }

  setup do
    sandbox_sessions!()
    :ok = MealPlannerApi.SubscriptionPlanFixtures.ensure_plans!()

    household = household!()
    consent!(household, household.owner)
    rice = ingredient!("Fictitious rice")
    recipe!("Fictitious rice bowl", [rice])

    %{household: household}
  end

  defp start!(household, script, opts \\ []) do
    attrs = session_attrs(household, household.owner, {@monday, @tuesday})

    defaults = [
      model: {Scripted, script: script, notify: self()},
      optimizer: {FakeOptimizer, notify: self()},
      subscriber: self(),
      call_policies: @fast
    ]

    {:ok, %{session_id: session_id, pid: pid}} =
      Session.start(attrs, Keyword.merge(defaults, opts))

    {session_id, pid}
  end

  defp model_requests(acc \\ 0) do
    receive do
      {:scripted_model_request, _} -> model_requests(acc + 1)
    after
      150 -> acc
    end
  end

  defp tool_result(%{messages: messages}, name) do
    %{content: content} =
      messages |> Enum.filter(&(&1.role == :tool_result and &1.name == name)) |> List.last()

    content
  end

  describe "model calls" do
    test "an attempt over the model deadline is killed and retried", %{household: h} do
      slow = fn _request -> Process.sleep(1_000) && {:text, "too late"} end
      {session_id, pid} = start!(h, [slow, {:text, "On time."}])

      :ok = Session.send_message(pid, "Plan")

      assert_receive {:planning_agent_event, ^session_id,
                      %{
                        "type" => "progress",
                        "step" => "retrying",
                        "call" => "model",
                        "attempt" => 2
                      }},
                     1_000

      assert_receive {:planning_agent_event, ^session_id,
                      %{"type" => "assistant_message", "text" => "On time."}},
                     1_000

      refute_received {:planning_agent_event, ^session_id,
                       %{"type" => "assistant_message", "text" => "too late"}}

      assert model_requests() == 2
    end

    test "transient failures are retried at most 5 times", %{household: h} do
      script = List.duplicate({:error, :provider_unavailable}, 7) ++ [{:text, "never"}]
      {session_id, pid} = start!(h, script)

      :ok = Session.send_message(pid, "Plan")

      assert_receive {:planning_agent_event, ^session_id,
                      %{"type" => "agent_unavailable", "reason" => "provider_unavailable"}},
                     2_000

      assert model_requests() == 6

      for attempt <- 2..6 do
        assert_received {:planning_agent_event, ^session_id,
                         %{"type" => "progress", "step" => "retrying", "attempt" => ^attempt}}
      end
    end

    test "a transient failure followed by an answer recovers", %{household: h} do
      {session_id, pid} = start!(h, [{:error, :provider_unavailable}, {:text, "Recovered."}])

      :ok = Session.send_message(pid, "Plan")

      assert_receive {:planning_agent_event, ^session_id,
                      %{"type" => "assistant_message", "text" => "Recovered."}},
                     1_000
    end

    test "backoff between retries increases", %{household: h} do
      script = List.duplicate({:error, :provider_unavailable}, 3) ++ [{:text, "ok"}]

      {session_id, pid} =
        start!(h, script, call_policies: %{model: %{timeout_ms: 1_000, backoff_ms: 60}})

      :ok = Session.send_message(pid, "Plan")

      times =
        for _ <- 1..4 do
          assert_receive {:scripted_model_request, _}, 2_000
          System.monotonic_time(:millisecond)
        end

      [first, second, third] =
        times |> Enum.chunk_every(2, 1, :discard) |> Enum.map(fn [a, b] -> b - a end)

      assert first >= 60
      assert second >= 120
      assert third >= 240
      assert_receive {:planning_agent_event, ^session_id, %{"type" => "assistant_message"}}, 1_000
    end

    for reason <- [
          :provider_unauthorized,
          :provider_rejected_request,
          :provider_conflict,
          :spend_cap_reached,
          :token_cap_reached
        ] do
      test "a #{reason} error is not retried", %{household: h} do
        reason = unquote(reason)
        {session_id, pid} = start!(h, [{:error, reason}, {:text, "never"}])

        :ok = Session.send_message(pid, "Plan")
        expected = Atom.to_string(reason)

        assert_receive {:planning_agent_event, ^session_id,
                        %{"type" => "agent_unavailable", "reason" => ^expected}},
                       1_000

        assert model_requests() == 1
        refute_received {:planning_agent_event, ^session_id, %{"step" => "retrying"}}
      end
    end

    test "no retry starts when its backoff would cross the global deadline", %{household: h} do
      {session_id, pid} =
        start!(h, [{:error, :provider_unavailable}, {:text, "never"}],
          call_policies: %{model: %{backoff_ms: 5_000}},
          deadline_ms: 500
        )

      :ok = Session.send_message(pid, "Plan")

      assert_receive {:planning_agent_event, ^session_id,
                      %{"type" => "agent_unavailable", "reason" => "provider_unavailable"}},
                     300

      assert model_requests() == 1
    end

    test "a model deadline longer than the global deadline is clipped", %{household: h} do
      slow = fn _request -> Process.sleep(5_000) && {:text, "too late"} end

      {session_id, pid} =
        start!(h, [slow], call_policies: %{model: %{timeout_ms: 60_000}}, deadline_ms: 200)

      :ok = Session.send_message(pid, "Plan")

      assert_receive {:planning_agent_event, ^session_id,
                      %{"type" => "limit_reached", "limit" => "time"}},
                     1_000

      assert model_requests() == 1
    end
  end

  describe "read tools" do
    test "a failed recipe search is retried at most 2 times", %{household: h} do
      steps = FakeRecipeSearch.steps!([:fail, :fail, :fail, {:ok, []}])

      {session_id, pid} =
        start!(
          h,
          [{:tool_calls, [{"search_recipes", %{"query" => "rice"}}]}, {:text, "Done."}],
          recipe_search: {FakeRecipeSearch, steps: steps, notify: self()}
        )

      :ok = Session.send_message(pid, "Plan")

      assert_receive {:planning_agent_event, ^session_id, %{"type" => "assistant_message"}},
                     1_000

      for _ <- 1..3, do: assert_received({:recipe_search, _})
      refute_received {:recipe_search, _}

      assert_received {:scripted_model_request, _}
      assert_received {:scripted_model_request, second}
      assert %{"error" => "search_failed"} = tool_result(second, "search_recipes")
    end

    test "a recipe search over its deadline is killed and retried", %{household: h} do
      steps = FakeRecipeSearch.steps!([{:sleep, 1_000}, {:ok, []}])

      {session_id, pid} =
        start!(
          h,
          [{:tool_calls, [{"search_recipes", %{"query" => "rice"}}]}, {:text, "Done."}],
          recipe_search: {FakeRecipeSearch, steps: steps, notify: self()}
        )

      :ok = Session.send_message(pid, "Plan")

      assert_receive {:planning_agent_event, ^session_id,
                      %{"type" => "progress", "step" => "retrying", "call" => "read"}},
                     1_000

      assert_receive {:planning_agent_event, ^session_id, %{"type" => "assistant_message"}},
                     1_000

      assert_received {:scripted_model_request, _}
      assert_received {:scripted_model_request, second}
      assert %{"recipes" => []} = tool_result(second, "search_recipes")
    end
  end

  describe "solver" do
    test "a solve over the solver deadline is inconclusive and not retried", %{household: h} do
      hang = fn payload -> Process.sleep(1_000) && FakeOptimizer.first_candidates(payload) end

      {session_id, pid} =
        start!(h, [{:tool_calls, [{"run_optimizer", %{}}]}, {:text, "Done."}],
          optimizer: {FakeOptimizer, notify: self(), result: hang}
        )

      :ok = Session.send_message(pid, "Plan")

      assert_receive {:planning_agent_event, ^session_id,
                      %{"type" => "optimizer_failed", "reason" => "optimizer_timeout"}},
                     1_000

      assert_receive {:planning_agent_event, ^session_id, %{"type" => "assistant_message"}},
                     1_000

      assert_received {:optimizer_payload, _}
      refute_received {:optimizer_payload, _}
    end

    test "the solver deadline reaches the optimizer, clipped by the global deadline",
         %{household: h} do
      test = self()

      capture = fn payload ->
        send(test, :solved)
        FakeOptimizer.first_candidates(payload)
      end

      {_session_id, pid} =
        start!(h, [{:tool_calls, [{"run_optimizer", %{}}]}, {:text, "Done."}],
          optimizer: {FakeOptimizer, notify_opts: self(), result: capture},
          call_policies: %{solver: %{timeout_ms: 120_000}},
          deadline_ms: 10_000
        )

      :ok = Session.send_message(pid, "Plan")

      assert_receive {:optimizer_opts, opts}, 1_000
      assert opts[:timeout_ms] <= 10_000
      assert_receive :solved
    end
  end
end
