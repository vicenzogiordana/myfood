defmodule MealPlannerApi.PlanningAgent.BrandsTest do
  @moduledoc """
  Brands through the session module with the scripted model, a fake
  optimizer and a fake scraper (issue #101, spec #93 user stories 50-54):
  Household Brand Preferences come from household settings, Session Brands
  live only in the Workspace, and the Purchase never swaps a chosen brand
  without telling the Member.
  """

  use ExUnit.Case, async: false

  import MealPlannerApi.PlanningAgentFixtures

  alias MealPlannerApi.BrandPreferences
  alias MealPlannerApi.PlanningAgent.{FakeOptimizer, FakeScraper}
  alias MealPlannerApi.PlanningAgent.Model.Scripted
  alias MealPlannerApi.PlanningAgent.Session

  @monday ~D[2026-11-02]
  @now ~U[2026-11-01 12:00:00.000000Z]

  setup do
    sandbox_sessions!()
    :ok = MealPlannerApi.SubscriptionPlanFixtures.ensure_plans!()

    household = household!()
    consent!(household, household.owner)

    %{household: household}
  end

  defp start!(household, script, opts \\ []) do
    attrs = session_attrs(household, household.owner, {@monday, @monday}, ["lunch"])

    {:ok, %{session_id: session_id, pid: pid}} =
      Session.start(attrs,
        model: {Scripted, script: script, notify: self()},
        optimizer: {FakeOptimizer, Keyword.get(opts, :optimizer, [])},
        price_scraper: {FakeScraper, responses: %{}, notify: self()},
        clock: fn -> @now end,
        subscriber: self()
      )

    {session_id, pid}
  end

  describe "Household Brand Preferences" do
    test "come from household settings into the agent's instructions", %{household: h} do
      pasta = ingredient!("Fictitious pasta")
      {:ok, _} = BrandPreferences.put(h.account_id, pasta.id, "Fictitious Luchetti")

      {_session_id, pid} = start!(h, [{:text, "Hello"}])
      :ok = Session.send_message(pid, "Hi")

      assert_receive {:scripted_model_request, %{instructions: instructions}}
      assert instructions =~ "#{pasta.name}: Fictitious Luchetti"
    end

    test "of another Household never reach this session", %{household: h} do
      pasta = ingredient!("Fictitious pasta")
      other = household!("Other Fictitious Household")
      {:ok, _} = BrandPreferences.put(other.account_id, pasta.id, "Fictitious Other Brand")

      {_session_id, pid} = start!(h, [{:text, "Hello"}])
      :ok = Session.send_message(pid, "Hi")

      assert_receive {:scripted_model_request, %{instructions: instructions}}
      refute instructions =~ "Fictitious Other Brand"
    end
  end
end
