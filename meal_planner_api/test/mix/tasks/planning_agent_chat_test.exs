defmodule Mix.Tasks.PlanningAgent.ChatTest do
  @moduledoc """
  The terminal chat over a real Planning Session, offline (`--scripted`):
  it seeds the fictitious Household, prints the code-built Proposal and the
  code-owned status line, and drives the human-only actions as commands.
  """

  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias MealPlannerApi.PlanningAgent.Chat.Household
  alias MealPlannerApi.PlanningAgent.Session
  alias MealPlannerApi.Repo
  alias Mix.Tasks.PlanningAgent.Chat

  setup do
    owner = Sandbox.start_owner!(Repo, shared: true)
    Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      Mix.shell(Mix.Shell.IO)
      Sandbox.stop_owner(owner)
    end)

    :ok
  end

  defp output do
    receive do
      {:mix_shell, :info, [line]} -> [line | output()]
    after
      0 -> []
    end
  end

  test "seeds the Household and plans, approves and confirms an over-budget Proposal" do
    result =
      Chat.run(["--scripted"],
        sandboxed: true,
        household: [budget_cents: 1_000],
        input: ["armame el plan de la semana", "/spend", "/approve", "/confirm"]
      )

    lines = output()
    text = Enum.join(lines, "\n")

    assert result.outcome == :confirmed
    assert result.spend_micros == 0
    assert "Household seeded." in lines
    assert text =~ ~r/--- proposal \w{8} \(requires_approval\) ---/
    assert text =~ "2026-11-02 lunch: "
    assert text =~ "deviation: budget exceeded by ARS "
    assert text =~ ~r/\[status\] proposal \w{8}: requires_approval, over budget \| run: complete/
    assert text =~ "[spend] US$0.0000"
    assert text =~ "Deviations approved"
    assert text =~ "Confirmed:"
    assert text =~ "Session spend: US$0.0000"

    {:existing, household} = Household.ensure()
    assert Session.whereis(household.account_id) == nil
  end

  test "a Proposal within budget is valid, and /quit cancels the session" do
    result = Chat.run(["--scripted"], sandboxed: true, input: ["plan the week", "/quit"])
    text = Enum.join(output(), "\n")

    assert result.outcome == :quit
    assert text =~ ~r/\[status\] proposal \w{8}: valid, within budget \| run: complete/
    refute text =~ "deviation:"

    {:existing, household} = Household.ensure()
    assert Session.whereis(household.account_id) == nil
  end

  test "end of input before any message quits without a Proposal" do
    result = Chat.run(["--scripted"], sandboxed: true, input: ["/confirm"])
    text = Enum.join(output(), "\n")

    assert result.outcome == :quit
    assert text =~ "No Proposal has been shown yet."
  end
end
