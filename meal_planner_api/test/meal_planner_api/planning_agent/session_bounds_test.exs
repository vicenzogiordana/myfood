defmodule MealPlannerApi.PlanningAgent.SessionBoundsTest do
  @moduledoc """
  Execution bounds of the planning agent session (#108, spec #93): per-call
  deadlines and retry budgets, observed through the session module with the
  scripted model, a fake recipe search and a fake optimizer.
  """

  use ExUnit.Case, async: false

  import MealPlannerApi.PlanningAgentFixtures

  require Ecto.Query

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
          :provider_conflict
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

    for {reason, limit} <- [spend_cap_reached: "spend_cap", token_cap_reached: "token_cap"] do
      test "a #{reason} refusal is not retried and exhausts the session", %{household: h} do
        {session_id, pid} = start!(h, [{:error, unquote(reason)}, {:text, "never"}])
        limit = unquote(limit)

        :ok = Session.send_message(pid, "Plan")

        assert_receive {:planning_agent_event, ^session_id,
                        %{"type" => "session_budget_exhausted", "limit" => ^limit}},
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

  describe "limits and authorization to continue" do
    defp fake_recipe(n),
      do: %{
        id: Ecto.UUID.generate(),
        name: "Fictitious recipe #{n}",
        slots: ["lunch"],
        ingredients: [],
        calories_per_serving: nil
      }

    # Every search finds the same recipe, without the database: under the
    # 100 ms read deadline of @fast a real search slowed by a loaded machine
    # was cut and retried, so a no-progress run outlived its assertion
    # (the intermittent failure of issue #151).
    defp same_evidence do
      recipe = fake_recipe(0)
      {FakeRecipeSearch, steps: FakeRecipeSearch.steps!(List.duplicate({:ok, [recipe]}, 20))}
    end

    defp search_forever(query),
      do: fn _request -> {:tool_calls, [{"search_recipes", %{"query" => query}}]} end

    # A Recipe Draft whose only Ingredient is `ingredient`.
    defp pizza_args(ingredient),
      do: %{
        "name" => "Imaginary pizza",
        "servings" => 2,
        "slots" => ["lunch"],
        "origin" => "ai_created",
        "ingredients" => [%{"ingredient" => ingredient, "quantity" => 300, "unit" => "g"}],
        "steps" => ["Bake it."]
      }

    test "every Member message gets its own iterations (issue #154)", %{household: h} do
      script = [
        {:tool_calls, [{"search_recipes", %{"query" => "rice"}}]},
        {:tool_calls, [{"search_recipes", %{"query" => "bowl"}}]},
        {:text, "First answer."},
        {:tool_calls, [{"search_recipes", %{"query" => "Fictitious"}}]},
        {:tool_calls, [{"search_recipes", %{"query" => "rice bowl"}}]},
        {:text, "Second answer."}
      ]

      # Every search finds a new recipe, so only the iteration limits apply.
      steps = FakeRecipeSearch.steps!(Enum.map(1..4, &{:ok, [fake_recipe(&1)]}))

      {session_id, pid} =
        start!(h, script, max_iterations: 3, recipe_search: {FakeRecipeSearch, steps: steps})

      :ok = Session.send_message(pid, "Plan")
      assert_receive {:planning_agent_event, ^session_id, %{"type" => "turn_completed"}}, 1_000

      # All three iterations were used; the new message gets three again.
      :ok = Session.send_message(pid, "Plan more")

      assert_receive {:planning_agent_event, ^session_id,
                      %{"type" => "assistant_message", "text" => "Second answer."}},
                     1_000

      assert_receive {:planning_agent_event, ^session_id, %{"type" => "turn_completed"}}, 1_000
      assert model_requests() == 6
    end

    test "the session ceiling ends the Planning Session gracefully", %{household: h} do
      script = [
        {:tool_calls, [{"search_recipes", %{"query" => "rice"}}]},
        {:text, "First answer."},
        {:tool_calls, [{"search_recipes", %{"query" => "bowl"}}]},
        {:text, "never"}
      ]

      {session_id, pid} = start!(h, script, max_iterations: 3, max_session_iterations: 3)
      ref = Process.monitor(pid)

      :ok = Session.send_message(pid, "Plan")
      assert_receive {:planning_agent_event, ^session_id, %{"type" => "turn_completed"}}, 1_000

      :ok = Session.send_message(pid, "Plan more")

      assert_receive {:planning_agent_event, ^session_id,
                      %{"type" => "session_budget_exhausted", "limit" => "session_iterations"} =
                        event},
                     1_000

      assert event["message"] =~ "new planning session"
      assert event["proposal"] == nil
      assert_receive {:planning_agent_event, ^session_id, %{"type" => "run_finished"}}, 1_000

      # Without a Proposal to confirm nothing is left to do: the session ends
      # and releases the Household, so a new one can start.
      assert_receive {:planning_agent_event, ^session_id, %{"type" => "session_ended"}}, 1_000
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
      assert model_requests() == 3
    end

    test "a call refused before reaching the provider is not counted", %{household: h} do
      script = [
        {:error, :provider_busy},
        {:tool_calls, [{"search_recipes", %{"query" => "rice"}}]},
        {:text, "Done."}
      ]

      no_retry = Map.put(@fast, :model, %{timeout_ms: 100, backoff_ms: 1, retries: 0})

      {session_id, pid} =
        start!(h, script, max_session_iterations: 2, call_policies: no_retry)

      :ok = Session.send_message(pid, "Plan")

      assert_receive {:planning_agent_event, ^session_id,
                      %{"type" => "agent_unavailable", "reason" => "provider_busy"}},
                     1_000

      assert_receive {:planning_agent_event, ^session_id, %{"type" => "run_finished"}}, 1_000

      # The refused call used none of the two iterations of the session.
      :ok = Session.send_message(pid, "Plan again")

      assert_receive {:planning_agent_event, ^session_id,
                      %{"type" => "assistant_message", "text" => "Done."}},
                     1_000

      refute_received {:planning_agent_event, ^session_id,
                       %{"type" => "session_budget_exhausted"}}
    end

    test "after a limit, nothing runs until the Member authorizes continuing", %{household: h} do
      # Every search finds a new recipe, so only the iteration limit applies.
      steps = FakeRecipeSearch.steps!(Enum.map(1..9, &{:ok, [fake_recipe(&1)]}))
      script = Enum.map(1..9, &search_forever("query #{&1}"))

      {session_id, pid} =
        start!(h, script, max_iterations: 2, recipe_search: {FakeRecipeSearch, steps: steps})

      :ok = Session.send_message(pid, "Plan")

      assert_receive {:planning_agent_event, ^session_id,
                      %{"type" => "limit_reached", "limit" => "iterations"}},
                     1_000

      assert model_requests() == 2

      assert :ok = Session.authorize_continuation(pid, h.owner.membership_id)

      assert_receive {:planning_agent_event, ^session_id,
                      %{"type" => "limit_reached", "limit" => "iterations"}},
                     1_000

      # The authorization granted exactly one more allowance of iterations.
      assert model_requests() == 2
    end

    test "only the session's Member may authorize continuing", %{household: h} do
      member = member!(h)
      consent!(h, member)
      attrs = session_attrs(h, member, {@monday, @tuesday})

      {:ok, %{session_id: session_id, pid: pid}} =
        Session.start(attrs,
          model: {Scripted, script: [search_forever("a"), search_forever("b")], notify: self()},
          subscriber: self(),
          max_iterations: 1
        )

      :ok = Session.send_message(pid, "Plan")

      assert_receive {:planning_agent_event, ^session_id, %{"type" => "limit_reached"}}, 1_000

      assert {:error, :forbidden} = Session.authorize_continuation(pid, h.owner.membership_id)
      assert :ok = Session.authorize_continuation(pid, member.membership_id)
    end

    test "authorizing without a reached limit is refused", %{household: h} do
      {_session_id, pid} = start!(h, [])

      assert {:error, :no_limit_reached} =
               Session.authorize_continuation(pid, h.owner.membership_id)
    end

    test "three attempts without verifiable progress stop and ask the Member", %{household: h} do
      # Every rewording finds the same recipe: new words, no new evidence.
      script = Enum.map(["rice", "bowl", "Fictitious", "rice bowl", "rice"], &search_forever/1)
      {session_id, pid} = start!(h, script, recipe_search: same_evidence())

      :ok = Session.send_message(pid, "Plan")

      assert_receive {:planning_agent_event, ^session_id,
                      %{
                        "type" => "limit_reached",
                        "limit" => "no_progress",
                        "requires_authorization" => true
                      }},
                     1_000

      # One attempt brought evidence, the next three did not.
      assert model_requests() == 4

      assert :ok = Session.authorize_continuation(pid, h.owner.membership_id)
      assert_receive {:scripted_model_request, _}, 1_000
    end

    # Issue #158: the Member is told "or send a new message" after a limit;
    # refusing that message left a dead end.
    test "a new message after an iteration limit starts a new run", %{household: h} do
      steps = FakeRecipeSearch.steps!(Enum.map(1..9, &{:ok, [fake_recipe(&1)]}))
      script = Enum.map(1..2, &search_forever("query #{&1}")) ++ [{:text, "Pizzas skipped."}]

      {session_id, pid} =
        start!(h, script, max_iterations: 2, recipe_search: {FakeRecipeSearch, steps: steps})

      :ok = Session.send_message(pid, "Plan")

      assert_receive {:planning_agent_event, ^session_id,
                      %{"type" => "limit_reached", "limit" => "iterations"}},
                     1_000

      assert model_requests() == 2

      assert :ok = Session.send_message(pid, "Skip the pizzas")

      assert_receive {:planning_agent_event, ^session_id,
                      %{"type" => "assistant_message", "text" => "Pizzas skipped."}},
                     1_000

      assert %{pending_limit: nil} = :sys.get_state(pid)

      # The new message is a request of its own: the Member's text reaches the model.
      assert_received {:scripted_model_request, %{messages: messages}}
      assert List.last(messages) == %{role: :user, content: "Skip the pizzas"}
    end

    test "a new message after a no-progress limit starts over its attempts", %{household: h} do
      script =
        Enum.map(["rice", "bowl", "Fictitious", "rice bowl"], &search_forever/1) ++
          Enum.map(["rice", "bowl", "rice"], &search_forever/1)

      {session_id, pid} = start!(h, script, recipe_search: same_evidence())

      :ok = Session.send_message(pid, "Plan")

      assert_receive {:planning_agent_event, ^session_id,
                      %{"type" => "limit_reached", "limit" => "no_progress"}},
                     1_000

      assert model_requests() == 4
      assert :ok = Session.send_message(pid, "Try something else")

      assert_receive {:planning_agent_event, ^session_id,
                      %{"type" => "limit_reached", "limit" => "no_progress"}},
                     1_000

      # Three more attempts without progress, not one: the streak started over.
      assert model_requests() == 3
    end

    test "a new message after a limit never passes the session's ceiling", %{household: h} do
      steps = FakeRecipeSearch.steps!(Enum.map(1..9, &{:ok, [fake_recipe(&1)]}))
      script = Enum.map(1..9, &search_forever("query #{&1}"))

      {session_id, pid} =
        start!(h, script,
          max_iterations: 2,
          max_session_iterations: 3,
          recipe_search: {FakeRecipeSearch, steps: steps}
        )

      :ok = Session.send_message(pid, "Plan")

      assert_receive {:planning_agent_event, ^session_id,
                      %{"type" => "limit_reached", "limit" => "iterations"}},
                     1_000

      assert :ok = Session.send_message(pid, "Go on")

      assert_receive {:planning_agent_event, ^session_id,
                      %{"type" => "session_budget_exhausted", "limit" => "session_iterations"}},
                     1_000

      # Two calls for the first message, one for the second, never more.
      assert model_requests() == 3
    end

    test "failed tool calls are not progress", %{household: h} do
      steps = FakeRecipeSearch.steps!(List.duplicate(:fail, 20))
      script = Enum.map(1..5, &search_forever("query #{&1}"))

      {session_id, pid} =
        start!(h, script, recipe_search: {FakeRecipeSearch, steps: steps})

      :ok = Session.send_message(pid, "Plan")

      assert_receive {:planning_agent_event, ^session_id,
                      %{"type" => "limit_reached", "limit" => "no_progress"}},
                     2_000

      assert model_requests() == 3
    end

    # Issue A7 of the quality battery: the model may retry broken tools until
    # the limit cuts the run without ever telling the Member. The code then
    # tells the Member which tools failed, whatever the model did.
    test "a run cut by failing tools tells the Member which tools failed", %{household: h} do
      steps = FakeRecipeSearch.steps!(List.duplicate(:fail, 20))
      calls = {:tool_calls, [{"search_recipes", %{"query" => "rice"}}, {"run_optimizer", %{}}]}

      {session_id, pid} =
        start!(h, List.duplicate(calls, 5), recipe_search: {FakeRecipeSearch, steps: steps})

      :ok = Session.send_message(pid, "Plan")

      assert_receive {:planning_agent_event, ^session_id,
                      %{"type" => "assistant_message", "text" => text}},
                     2_000

      assert text =~ "recipe search (search failed)"
      assert text =~ "meal plan optimizer (search failed)"
      assert text =~ "try again later"
      refute text =~ "?"

      assert_receive {:planning_agent_event, ^session_id,
                      %{"type" => "limit_reached", "limit" => "no_progress"}}

      assert_receive {:planning_agent_event, ^session_id,
                      %{"type" => "run_finished", "outcome" => "partial"}}
    end

    test "the notice names an unavailable optimizer and its reason", %{household: h} do
      script = List.duplicate({:tool_calls, [{"run_optimizer", %{}}]}, 5)

      {session_id, pid} =
        start!(h, script, optimizer: {MealPlannerApi.PlanningAgent.Optimizer.Unavailable, []})

      :ok = Session.send_message(pid, "Plan")

      assert_receive {:planning_agent_event, ^session_id,
                      %{"type" => "assistant_message", "text" => text}},
                     2_000

      assert text =~ "meal plan optimizer (optimizer unavailable)"
      refute text =~ "recipe search"

      assert_receive {:planning_agent_event, ^session_id,
                      %{"type" => "limit_reached", "limit" => "no_progress"}}
    end

    # Issue #158: the model guessed ingredient names the catalog does not
    # have until the no-progress limit cut the run, without a word to the
    # Member. The code then names the recipe and the missing ingredients.
    test "a run cut by repeated unknown ingredients names the recipe and the ingredients",
         %{household: h} do
      script =
        Enum.map(
          ["Imaginary flour", "Imaginary wheat flour", "Imaginary flour", "Imaginary dough"],
          &{:tool_calls, [{"create_recipe", pizza_args(&1)}]}
        )

      {session_id, pid} = start!(h, script)

      :ok = Session.send_message(pid, "Pizzas on Monday lunch")

      assert_receive {:planning_agent_event, ^session_id,
                      %{"type" => "assistant_message", "text" => text}},
                     2_000

      assert text =~
               "the recipe for Imaginary pizza needs ingredients that are not in the catalog: " <>
                 "Imaginary flour, Imaginary wheat flour"

      refute text =~ "our side"
      refute text =~ "?"

      assert_receive {:planning_agent_event, ^session_id,
                      %{"type" => "limit_reached", "limit" => "no_progress"}}
    end

    test "a single rejected recipe before progress adds no notice", %{household: h} do
      script = [
        {:tool_calls, [{"create_recipe", pizza_args("Imaginary flour")}]},
        search_forever("rice"),
        search_forever("rice"),
        search_forever("rice"),
        search_forever("rice")
      ]

      {session_id, pid} = start!(h, script, recipe_search: same_evidence())

      :ok = Session.send_message(pid, "Plan")

      assert_receive {:planning_agent_event, ^session_id,
                      %{"type" => "limit_reached", "limit" => "no_progress"}},
                     2_000

      refute_received {:planning_agent_event, ^session_id, %{"type" => "assistant_message"}}
    end

    # A fixed meal whose Recipe is gone is the Member's own choice, not a
    # service outage, so the notice must not blame the service for it.
    test "a run cut by an unavailable fixed meal names it without blaming the service",
         %{household: h} do
      pinned = recipe!("Fictitious pinned stew", [ingredient!("Fictitious stew beans")])
      successor = recipe!("Fictitious successor stew", [ingredient!("Fictitious stew lentils")])

      supersede = fn _request ->
        MealPlannerApi.Repo.update_all(
          Ecto.Query.from(r in MealPlannerApi.Persistence.Catalog.Recipe,
            where: r.id == ^pinned.id
          ),
          set: [superseded_by_id: successor.id]
        )

        {:tool_calls, [{"run_optimizer", %{}}]}
      end

      pin =
        {:tool_calls,
         [
           {"edit_workspace",
            %{
              "action" => "pin",
              "date" => "2026-11-02",
              "slot" => "dinner",
              "recipe_id" => pinned.id
            }}
         ]}

      script = [pin, supersede | List.duplicate({:tool_calls, [{"run_optimizer", %{}}]}, 5)]
      {session_id, pid} = start!(h, script)

      :ok = Session.send_message(pid, "Plan")

      assert_receive {:planning_agent_event, ^session_id,
                      %{"type" => "limit_reached", "limit" => "no_progress"}},
                     2_000

      last_request =
        Enum.reduce_while(Stream.repeatedly(fn -> nil end), nil, fn _, last ->
          receive do
            {:scripted_model_request, request} -> {:cont, request}
          after
            0 -> {:halt, last}
          end
        end)

      assert %{"error" => "fixed_meal_unavailable"} = tool_result(last_request, "run_optimizer")

      assert_received {:planning_agent_event, ^session_id,
                       %{"type" => "assistant_message", "text" => text}}

      assert text =~ "meal plan optimizer kept rejecting the request (fixed meal unavailable)"
      refute text =~ "our side"
      refute text =~ "try again later"
    end

    test "a limit reached without failing tools adds no notice", %{household: h} do
      script = Enum.map(["rice", "bowl", "Fictitious", "rice bowl", "rice"], &search_forever/1)
      {session_id, pid} = start!(h, script, recipe_search: same_evidence())

      :ok = Session.send_message(pid, "Plan")

      assert_receive {:planning_agent_event, ^session_id,
                      %{"type" => "limit_reached", "limit" => "no_progress"}},
                     1_000

      refute_received {:planning_agent_event, ^session_id, %{"type" => "assistant_message"}}
    end

    test "a time limit is continued by the Member's authorization", %{household: h} do
      slow = fn _request -> Process.sleep(1_000) && {:text, "late"} end

      {session_id, pid} =
        start!(h, [slow, {:text, "Continued."}],
          call_policies: %{model: %{timeout_ms: 5_000}},
          deadline_ms: 100
        )

      :ok = Session.send_message(pid, "Plan")

      assert_receive {:planning_agent_event, ^session_id,
                      %{
                        "type" => "limit_reached",
                        "limit" => "time",
                        "requires_authorization" => true
                      }},
                     1_000

      assert :ok = Session.authorize_continuation(pid, h.owner.membership_id)

      assert_receive {:planning_agent_event, ^session_id,
                      %{"type" => "assistant_message", "text" => "Continued."}},
                     1_000
    end

    test "iterations of a turn killed at the deadline stay counted", %{household: h} do
      slow = fn _request -> Process.sleep(1_000) && {:text, "late"} end

      {session_id, pid} =
        start!(h, [search_forever("rice"), slow, {:text, "never"}],
          call_policies: %{model: %{timeout_ms: 5_000}},
          deadline_ms: 200,
          max_iterations: 2
        )

      :ok = Session.send_message(pid, "Plan")

      assert_receive {:planning_agent_event, ^session_id,
                      %{"type" => "limit_reached", "limit" => "time"}},
                     1_000

      assert :ok = Session.authorize_continuation(pid, h.owner.membership_id)

      assert_receive {:planning_agent_event, ^session_id,
                      %{"type" => "limit_reached", "limit" => "iterations"}},
                     1_000

      refute_received {:planning_agent_event, ^session_id, %{"text" => "never"}}
    end
  end

  describe "outcome kinds" do
    defp run_outcome(session_id) do
      assert_receive {:planning_agent_event, ^session_id,
                      %{"type" => "run_finished", "outcome" => outcome}},
                     2_000

      outcome
    end

    test "every tool result carries its outcome kind", %{household: h} do
      steps = FakeRecipeSearch.steps!([{:ok, []}, :fail, {:sleep, 1_000}])

      script = [
        {:tool_calls,
         [
           {"search_recipes", %{"query" => "a"}},
           {"search_recipes", %{"query" => "b"}},
           {"present_proposal", %{}},
           {"no_such_tool", %{}}
         ]},
        {:tool_calls, [{"search_recipes", %{"query" => "c"}}]},
        {:text, "Done."}
      ]

      {session_id, pid} =
        start!(h, script,
          recipe_search: {FakeRecipeSearch, steps: steps},
          call_policies: %{read: %{timeout_ms: 50, retries: 0}}
        )

      :ok = Session.send_message(pid, "Plan")
      assert run_outcome(session_id) == "complete"

      assert_received {:scripted_model_request, _}
      assert_received {:scripted_model_request, second}
      assert_received {:scripted_model_request, third}

      outcomes =
        for %{role: :tool_result, content: content} <- third.messages, do: content["outcome"]

      # complete search, failed search, nothing to present, unknown tool,
      # and a search cut at its deadline: not "no recipes", but unknown.
      assert outcomes == ["complete", "failure", "failure", "failure", "unknown"]
      assert length(second.messages) < length(third.messages)

      for outcome <- ["complete", "failure", "unknown"] do
        assert_received {:planning_agent_event, ^session_id,
                         %{"type" => "progress", "step" => "tool_finished", "outcome" => ^outcome}}
      end
    end

    test "an optimizer plan built without prices is partial and names what is missing",
         %{household: h} do
      {session_id, pid} =
        start!(h, [{:tool_calls, [{"run_optimizer", %{}}]}, {:text, "Done."}])

      :ok = Session.send_message(pid, "Plan")
      assert run_outcome(session_id) == "complete"

      assert_received {:scripted_model_request, _}
      assert_received {:scripted_model_request, second}

      assert %{"status" => "ok", "outcome" => "partial", "missing" => missing} =
               tool_result(second, "run_optimizer")

      assert "estimated_cost" in missing
      assert "protein_g_per_serving" in missing

      assert_received {:optimizer_payload, payload}
      [candidate | _] = payload["candidates_by_slot"]["lunch"]
      # Missing nutrition is sent as missing, never as zero.
      assert candidate["protein_g_per_serving"] == nil
    end

    test "an optimizer timeout is unknown, never failure or infeasible", %{household: h} do
      {session_id, pid} =
        start!(h, [{:tool_calls, [{"run_optimizer", %{}}]}, {:text, "Done."}],
          optimizer: {FakeOptimizer, result: fn _ -> {:error, :optimizer_timeout, %{}} end}
        )

      :ok = Session.send_message(pid, "Plan")
      assert run_outcome(session_id) == "complete"

      assert_received {:scripted_model_request, _}
      assert_received {:scripted_model_request, second}
      assert %{"outcome" => "unknown"} = tool_result(second, "run_optimizer")
    end

    test "a run stopped by a limit is partial", %{household: h} do
      script =
        Enum.map(1..3, fn n -> {:tool_calls, [{"search_recipes", %{"query" => "#{n}"}}]} end)

      {session_id, pid} = start!(h, script, max_iterations: 1)

      :ok = Session.send_message(pid, "Plan")
      assert run_outcome(session_id) == "partial"
    end

    test "a run whose model fails is a failure", %{household: h} do
      {session_id, pid} = start!(h, [{:error, :provider_unauthorized}])

      :ok = Session.send_message(pid, "Plan")
      assert run_outcome(session_id) == "failure"
    end

    test "a run that crashes is unknown", %{household: h} do
      crash = fn _request -> raise "fictitious crash" end
      {session_id, pid} = start!(h, [crash])

      ExUnit.CaptureLog.capture_log(fn ->
        :ok = Session.send_message(pid, "Plan")
        assert run_outcome(session_id) == "unknown"
      end)
    end

    test "a run interrupted by Cancel is cancelled", %{household: h} do
      slow = fn _request -> Process.sleep(5_000) && {:text, "late"} end

      {session_id, pid} =
        start!(h, [slow], call_policies: %{model: %{timeout_ms: 10_000}})

      :ok = Session.send_message(pid, "Plan")
      assert_receive {:scripted_model_request, _}, 1_000

      :ok = Session.cancel(pid, %{membership_id: h.owner.membership_id, owner?: true})
      assert run_outcome(session_id) == "cancelled"
    end
  end

  describe "streaming" do
    @sentinel "SENTINEL-raw-tool-output"

    test "streamed events carry progress only, never raw tool output", %{household: h} do
      raw_recipe = %{
        id: Ecto.UUID.generate(),
        name: "#{@sentinel} recipe",
        slots: ["lunch"],
        ingredients: ["#{@sentinel} ingredient"],
        calories_per_serving: nil
      }

      # The search itself, then the optimizer's lunch and dinner candidates.
      steps = FakeRecipeSearch.steps!(List.duplicate({:ok, [raw_recipe]}, 3))
      failing = fn _ -> {:error, :infeasible, %{"causes" => [@sentinel]}} end

      script = [
        {:tool_calls,
         [
           {"search_recipes", %{"query" => @sentinel}},
           {"run_optimizer", %{"exclude_recipe_ids" => [@sentinel]}},
           {@sentinel, %{"x" => @sentinel}}
         ]},
        {:text, "Done."}
      ]

      {session_id, pid} =
        start!(h, script,
          recipe_search: {FakeRecipeSearch, steps: steps},
          optimizer: {FakeOptimizer, result: failing}
        )

      :ok = Session.send_message(pid, "Plan")
      assert run_outcome(session_id) == "complete"

      events = collect_events(session_id)
      assert Enum.any?(events, &(&1["type"] == "optimizer_failed"))
      refute inspect(events, limit: :infinity, printable_limit: :infinity) =~ @sentinel
    end

    defp collect_events(session_id, acc \\ []) do
      receive do
        {:planning_agent_event, ^session_id, event} -> collect_events(session_id, [event | acc])
      after
        0 -> Enum.reverse(acc)
      end
    end
  end
end
