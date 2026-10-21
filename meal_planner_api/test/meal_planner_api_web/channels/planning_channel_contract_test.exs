defmodule MealPlannerApiWeb.PlanningChannelContractTest do
  @moduledoc """
  The planning channel's client contract (`docs/CHANNELS.md`, issue #169)
  against the code: every documented `agent_event` type and its fields
  against the Session's event allowlist, every documented incoming event
  against the channel, and the documented Proposal fields against a
  Proposal the channel really pushes. A drift on either side fails here.
  """

  use MealPlannerApiWeb.ChannelCase, async: false

  import MealPlannerApi.FactoryHelpers, only: [issue_access_v2_token: 2]
  import MealPlannerApi.PlanningAgentFixtures

  alias MealPlannerApi.Persistence.Accounts.{Account, AccountMembership, User}
  alias MealPlannerApi.PlanningAgent.FakeOptimizer
  alias MealPlannerApi.PlanningAgent.Model.Scripted
  alias MealPlannerApi.PlanningAgent.Session
  alias MealPlannerApi.Repo
  alias MealPlannerApiWeb.{PlanningAgentChannel, UserSocket}

  @doc_path Path.expand("../../../docs/CHANNELS.md", __DIR__)
  @external_resource @doc_path

  @range %{"range_from" => "2026-11-02", "range_to" => "2026-11-02", "slots" => ["dinner"]}

  # The planning section of the doc, up to the next channel.
  defp planning_section do
    [_before, rest] = @doc_path |> File.read!() |> String.split("### planning:*", parts: 2)
    rest |> String.split("\n### ", parts: 2) |> hd()
  end

  # The rows of the table under `#### <heading>` in the planning section.
  defp table(heading) do
    [_before, rest] = String.split(planning_section(), "#### #{heading}\n", parts: 2)

    rest
    |> String.split("\n#### ", parts: 2)
    |> hd()
    |> String.split("\n")
    # Body rows only: a table's header is the row right above its `|---`.
    |> Enum.drop_while(&(not String.starts_with?(&1, "|---")))
    |> Enum.filter(&String.starts_with?(&1, "| `"))
    |> Enum.map(fn row ->
      row |> String.trim("|") |> String.split(" | ") |> Enum.map(&String.trim/1)
    end)
  end

  defp code(cell), do: cell |> String.trim("`")

  # `{a, b?, c}` -> ["a", "b", "c"]
  defp fields(cell) do
    [_, inner] = Regex.run(~r/^`\{([^}]*)\}`/, cell)

    inner
    |> String.split(",", trim: true)
    |> Enum.map(&(&1 |> String.trim() |> String.trim_trailing("?")))
    |> Enum.reject(&(&1 == ""))
  end

  # Every backticked word of a cell.
  defp codes(cell), do: ~r/`([a-z_]+)`/ |> Regex.scan(cell) |> Enum.map(&List.last/1)

  describe "agent_event types" do
    test "the documented types are exactly the Session's allowlist" do
      documented = table("Outgoing Events") |> Enum.map(&code(hd(&1))) |> Enum.sort()
      assert documented == Session.event_fields() |> Map.keys() |> Enum.sort()
    end

    test "every documented type lists exactly the fields the Session lets through" do
      for [type, payload | _] <- table("Outgoing Events") do
        type = code(type)

        assert Enum.sort(fields(payload)) == Enum.sort(Map.fetch!(Session.event_fields(), type)),
               "documented fields of #{type} drifted from the allowlist"
      end
    end
  end

  describe "Proposal" do
    setup :household_with_agent

    test "the documented Proposal and Purchase fields are what the channel pushes",
         %{household: h} do
      documented = table("Proposal") |> Enum.map(&code(hd(&1)))
      purchase_documented = table("Proposal Purchase") |> Enum.map(&code(hd(&1)))

      top = Enum.reject(documented, &String.contains?(&1, "."))
      meal = for "meals[]." <> field <- documented, do: field

      assert Enum.sort(top) == Enum.sort(Map.fetch!(Session.event_fields(), "proposal"))
      assert Enum.sort(meal) == Enum.sort(Session.meal_fields())

      socket = join!(h, h.owner)
      ref = push(socket, "start_session", @range)
      assert_reply(ref, :ok, _)
      ref = push(socket, "give_consent", %{})
      assert_reply(ref, :ok, _)
      ref = push(socket, "send_message", %{"text" => "Plan dinner"})
      assert_reply(ref, :ok, _)
      assert_push("agent_event", %{"type" => "proposal"} = proposal)

      assert proposal |> Map.drop(["type", "session_id"]) |> Map.keys() |> Enum.sort() ==
               Enum.sort(top)

      for meal_data <- proposal["meals"] do
        assert meal_data |> Map.keys() |> Enum.sort() == Enum.sort(meal)
      end

      purchase =
        for "purchase." <> field <- purchase_documented,
            not String.contains?(field, "."),
            do: field

      line = for "purchase.lines[]." <> field <- purchase_documented, do: field

      assert proposal["purchase"] |> Map.keys() |> Enum.sort() == Enum.sort(purchase)

      for line_data <- proposal["purchase"]["lines"] do
        assert line_data |> Map.keys() |> Enum.sort() == Enum.sort(line)
      end

      ref = push(socket, "cancel_session", %{})
      assert_reply(ref, :ok, _)
    end
  end

  describe "incoming events" do
    setup :household_with_agent

    test "every documented event is served and replies only documented reasons",
         %{household: h} do
      socket = join!(h, h.owner)
      rows = table("Incoming Events")
      documented = for [event | _] <- rows, event != "any other event", do: code(event)

      # A payload carrying every documented field, well formed.
      probe = %{
        "range_from" => "2026-11-02",
        "range_to" => "2026-11-02",
        "slots" => ["dinner"],
        "text" => "Plan dinner",
        "recipe_id" => Ecto.UUID.generate(),
        "proposal_id" => Ecto.UUID.generate(),
        "member_id" => Ecto.UUID.generate(),
        "restriction" => %{"kind" => "diet", "value" => "vegetarian"},
        "meals" => [%{"date" => "2026-11-02", "slot" => "dinner"}]
      }

      replies = for [event, _payload, reply] <- rows, into: %{}, do: {code(event), codes(reply)}
      assert Map.keys(replies) |> Enum.sort() == Enum.sort(documented)
      check = fn event -> assert_documented_reply(socket, event, probe, replies[event]) end

      # Without a session, then within one (without consent, so no turn runs
      # and Stop never kills one mid-query), then a second start.
      Enum.each(documented -- ["start_session"], check)
      check.("start_session")
      Enum.each(documented -- ["start_session", "cancel_session", "give_consent"], check)
      check.("give_consent")
      check.("start_session")
      check.("cancel_session")

      ref = push(socket, "not_a_documented_event", %{})
      assert_reply(ref, :error, %{reason: "invalid_payload"})
    end
  end

  defp assert_documented_reply(socket, event, probe, documented_reasons) do
    ref = push(socket, event, probe)

    receive do
      %Phoenix.Socket.Reply{ref: ^ref, status: :ok} ->
        :ok

      %Phoenix.Socket.Reply{ref: ^ref, status: :error, payload: %{reason: reason}} ->
        assert reason in documented_reasons,
               "#{event} replied #{reason}, not documented (#{inspect(documented_reasons)})"
    after
      5_000 -> flunk("#{event} did not reply")
    end
  end

  defp household_with_agent(_context) do
    household = household!()
    _ = persist_trial_window!(Repo.get!(Account, household.account_id), :eligible)
    leek = ingredient!("Fictitious contract leek")
    product!(leek, price_cents: 100)
    recipe!("Fictitious contract soup", [leek], slots: ["dinner"])

    previous = Application.get_env(:meal_planner_api, :planning_agent)
    on_exit(fn -> Application.put_env(:meal_planner_api, :planning_agent, previous) end)

    configured = Application.get_env(:meal_planner_api, :planning_agent, [])

    script = [
      {:tool_calls, [{"run_optimizer", %{}}]},
      {:tool_calls, [{"present_proposal", %{}}]},
      {:text, "Here is your dinner."}
    ]

    Application.put_env(
      :meal_planner_api,
      :planning_agent,
      Keyword.merge(configured,
        model: {Scripted, script: script},
        optimizer: {FakeOptimizer, []}
      )
    )

    %{household: household}
  end

  defp join!(household, member) do
    token =
      issue_access_v2_token(
        Repo.get!(User, member.user_id),
        Repo.get!(AccountMembership, member.membership_id)
      )

    {:ok, socket} = connect(UserSocket, %{"token" => token})

    {:ok, _reply, socket} =
      subscribe_and_join(socket, PlanningAgentChannel, "planning:#{household.account_id}")

    socket
  end
end
