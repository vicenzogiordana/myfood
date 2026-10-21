defmodule Mix.Tasks.PlanningAgent.ChatTest do
  @moduledoc """
  The terminal chat over a real Planning Session, offline (`--scripted`):
  it seeds the fictitious Household, prints the code-built Proposal and the
  code-owned status line, and drives the human-only actions as commands.
  """

  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias MealPlannerApi.PlanningAgent.Chat.{Household, Repl, Scripted}
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

  test "/quit from standard input survives the still-blocked reader and cancels the session" do
    test_pid = self()

    {chat, ref} =
      spawn_monitor(fn ->
        Process.group_leader(self(), spawn_link(fn -> blocking_stdin(["/quit\n"]) end))
        result = Chat.run(["--scripted"], sandboxed: true, input: :stdio)
        send(test_pid, {:chat_done, result, output()})
      end)

    assert_receive {:chat_done, result, lines}, 5_000
    assert_receive {:DOWN, ^ref, :process, ^chat, :normal}

    assert result.outcome == :quit
    assert Enum.any?(lines, &String.starts_with?(&1, "Session spend: "))

    {:existing, household} = Household.ensure()
    assert Session.whereis(household.account_id) == nil
  end

  test "--reset refuses a database whose name does not end in _chat" do
    # The sandboxed test database (MYFOOD_TEST_DATABASE) is never emptied.
    assert_raise Mix.Error, ~r/only empties a database whose name ends in _chat/, fn ->
      Chat.run(["--reset", "--scripted"], sandboxed: true, input: [])
    end

    refute "Chat database emptied." in output()
  end

  test "an interrupted seed leaves no Household behind, so the next run seeds again" do
    broken_pantry = [%{ingredient: :not_in_the_catalog, quantity_milli: 1_000, unit: :g}]

    assert_raise KeyError, fn -> Household.ensure(pantry: broken_pantry) end

    assert {:seeded, _household} = Household.ensure()
  end

  test "a session that dies under a bare Session call still prints the spend summary" do
    {:seeded, household} = Household.ensure()
    test_pid = self()

    # Kills the session once, the first time the chat waits for input.
    kill_session = fn ->
      if pid = Session.whereis(household.account_id) do
        Process.exit(pid, :kill)
        send(test_pid, :session_killed)
      end
    end

    result =
      Repl.run(household,
        model: Scripted.model(),
        optimizer: {Scripted, []},
        input: ["/confirm"],
        prompt: kill_session
      )

    assert_received :session_killed
    assert result.outcome == :session_ended
    assert Enum.any?(output(), &String.starts_with?(&1, "Session spend: "))
  end

  # A group leader whose reads answer `lines` and then block forever, like a
  # terminal nobody types into.
  defp blocking_stdin(lines) do
    receive do
      {:io_request, from, reply_as, {:get_line, _encoding, _prompt}} ->
        case lines do
          [line | rest] ->
            send(from, {:io_reply, reply_as, line})
            blocking_stdin(rest)

          [] ->
            blocking_stdin([])
        end

      {:io_request, from, reply_as, _request} ->
        send(from, {:io_reply, reply_as, :ok})
        blocking_stdin(lines)
    end
  end
end
