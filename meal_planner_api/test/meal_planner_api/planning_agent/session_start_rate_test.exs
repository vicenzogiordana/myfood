defmodule MealPlannerApi.PlanningAgent.SessionStartRateTest do
  @moduledoc """
  Planning Session starts are rate limited per Household (spec #93, issue
  #118): at most `max_starts` starts within a sliding window of
  `window_seconds`. The limit is a human decision and comes only from
  configuration; without it no Planning Session starts.
  """

  use ExUnit.Case, async: false

  import Ecto.Query
  import MealPlannerApi.PlanningAgentFixtures

  alias MealPlannerApi.Persistence.Planning.PlanningSession
  alias MealPlannerApi.PlanningAgent.Model.Scripted
  alias MealPlannerApi.PlanningAgent.Session
  alias MealPlannerApi.Repo

  @monday ~D[2026-11-02]
  @tuesday ~D[2026-11-03]

  setup do
    sandbox_sessions!()
    :ok = MealPlannerApi.SubscriptionPlanFixtures.ensure_plans!()

    %{household: household!(), other: household!("Fictitious Other Household")}
  end

  defp start(household, opts) do
    Session.start(
      session_attrs(household, household.owner, {@monday, @tuesday}),
      Keyword.merge([model: {Scripted, script: []}], opts)
    )
  end

  defp start_and_cancel!(household, opts) do
    {:ok, %{pid: pid}} = start(household, opts)
    :ok = Session.cancel(pid, %{membership_id: household.owner.membership_id, owner?: true})
  end

  describe "rate limit" do
    test "refuses a start once the Household reached its starts in the window", %{
      household: household,
      other: other
    } do
      opts = [session_start_limit: {2, 3_600}]

      start_and_cancel!(household, opts)
      start_and_cancel!(household, opts)

      assert {:error, :session_start_rate_limited} = start(household, opts)

      # The limit is per Household: another Household still starts.
      assert {:ok, _} = start(other, opts)
    end

    test "starts older than the window no longer count", %{household: household} do
      opts = [session_start_limit: {1, 60}]

      start_and_cancel!(household, opts)
      assert {:error, :session_start_rate_limited} = start(household, opts)

      two_minutes_ago = DateTime.add(DateTime.utc_now(), -120, :second)

      Repo.update_all(from(s in PlanningSession, where: s.account_id == ^household.account_id),
        set: [started_at: two_minutes_ago]
      )

      assert {:ok, _} = start(household, opts)
    end

    test "a refused start leaves no Planning Session behind", %{household: household} do
      opts = [session_start_limit: {1, 3_600}]

      start_and_cancel!(household, opts)
      assert {:error, :session_start_rate_limited} = start(household, opts)

      count =
        Repo.aggregate(
          from(s in PlanningSession, where: s.account_id == ^household.account_id),
          :count
        )

      assert count == 1
    end
  end

  describe "configuration" do
    test "an unconfigured limit refuses every start with spend_caps_unconfigured", %{
      household: household
    } do
      assert {:error, :spend_caps_unconfigured} = start(household, session_start_limit: nil)
    end

    test "a malformed limit refuses every start with spend_caps_unconfigured", %{
      household: household
    } do
      for limit <- [{0, 60}, {1, 0}, {-1, 60}, {"2", 60}, 5, :unlimited] do
        assert {:error, :spend_caps_unconfigured} = start(household, session_start_limit: limit)
      end
    end

    test "the limit comes from the planning agent configuration by default", %{
      household: household
    } do
      configured = Application.fetch_env!(:meal_planner_api, :planning_agent)
      assert {max_starts, _window} = Keyword.fetch!(configured, :session_start_limit)
      assert is_integer(max_starts) and max_starts > 0

      assert {:ok, _} = start(household, [])
    end
  end
end
