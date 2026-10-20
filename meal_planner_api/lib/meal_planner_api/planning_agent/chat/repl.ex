defmodule MealPlannerApi.PlanningAgent.Chat.Repl do
  @moduledoc """
  An interactive terminal chat over one real Planning Session
  (`mix planning_agent.chat`): Member lines go to the agent, its messages,
  questions and Proposals are printed, and the human-only actions
  (Deviation Approval, confirmation, Stop) are commands.

  The session runs exactly as the app runs it (`MealPlannerApi.PlanningAgent.Session`):
  the agent loop, the validator, the limits and the per-session spend and
  token caps are the production ones. The model adapter is wrapped in the
  battery's meter (`MealPlannerApi.PlanningAgent.Battery.MeteredModel`), which
  reads the adapter's Spend Ledger, so `/spend` shows the session's spend.

  Input is read by a separate process, so `/stop` and `/spend` act while
  the agent works; any other line typed meanwhile waits until the run ends.
  End of input acts as `/quit`.
  """

  alias MealPlannerApi.PlanningAgent.Battery.{MeteredModel, PreparedScraper, Tasks}
  alias MealPlannerApi.PlanningAgent.Chat.Render
  alias MealPlannerApi.PlanningAgent.Session
  alias MealPlannerApi.Data.PlanningRepo

  @help [
    "Commands:",
    "  /approve   approve every Deviation of the shown Proposal",
    "  /confirm   confirm the shown Proposal (saves the plan and the shopping list)",
    "  /continue  authorize one more stretch after a limit was reached",
    "  /stop      halt the agent's current work (the session survives)",
    "  /spend     paid spend of this session so far",
    "  /help      this help",
    "  /quit      cancel the session and exit",
    "Anything else is sent to the agent."
  ]

  @immediate ["/stop", "/spend", "/help"]

  @doc """
  Runs the chat for `household` until `/quit`, a confirmation, the end of
  the session or the end of input. Returns the outcome and the spend.

  Options: `:model` and `:optimizer` (`{module, opts}`), `:input` (a list
  of lines, for tests; default: standard input), `:spend_cap_micros` (shown
  by `/spend`), `:session_opts` (extra `Session.start/2` options) and
  `:prompt` (a 0-arity function printing the prompt).
  """
  @spec run(map(), keyword()) :: %{
          outcome: :quit | :confirmed | :session_ended | {:start_refused, term()},
          spend_micros: non_neg_integer()
        }
  def run(household, opts) do
    {:ok, meter} = Agent.start_link(fn -> %{} end)
    release_stale_session(household)

    session_opts =
      [
        model: {MeteredModel, inner: Keyword.fetch!(opts, :model), meter: meter, run: :chat},
        optimizer: Keyword.fetch!(opts, :optimizer),
        price_scraper: {PreparedScraper, []},
        clock: &Tasks.now/0,
        subscriber: self(),
        session_start_limit: {1_000, 60}
      ] ++ Keyword.get(opts, :session_opts, [])

    outcome =
      case Session.start(attrs(household), session_opts) do
        {:ok, %{session_id: session_id, pid: pid}} ->
          reader = start_reader(Keyword.get(opts, :input, :stdio))

          state = %{
            household: household,
            session_id: session_id,
            pid: pid,
            meter: meter,
            reader: reader,
            spend_cap: Keyword.get(opts, :spend_cap_micros),
            prompt: Keyword.get(opts, :prompt, fn -> :ok end),
            busy: false,
            queue: :queue.new(),
            outcome: nil,
            proposal: nil
          }

          header(household)

          try do
            loop(state)
          after
            Process.exit(reader, :kill)
            end_session(pid, household)
          end

        {:error, reason} ->
          info("The session did not start: #{inspect(reason)}#{start_hint(reason)}")
          {:start_refused, reason}
      end

    spend = spend(meter)
    Agent.stop(meter)
    info("Session spend: #{Render.usd(spend)} (#{spend} micro-USD)")
    %{outcome: outcome, spend_micros: spend}
  end

  # ---------------------------------------------------------------------------
  # Loop
  # ---------------------------------------------------------------------------

  defp loop(%{busy: false} = state) do
    case :queue.out(state.queue) do
      {{:value, line}, queue} ->
        state |> Map.put(:queue, queue) |> handle(line) |> continue()

      {:empty, _queue} ->
        state.prompt.()
        state |> await() |> continue()
    end
  end

  defp loop(state), do: state |> await() |> continue()

  defp continue({:halt, outcome}), do: outcome
  defp continue(state), do: loop(state)

  defp await(%{session_id: session_id} = state) do
    receive do
      {:chat_input, line} -> input(state, line)
      {:planning_agent_event, ^session_id, event} -> event(state, event)
    end
  end

  defp input(%{busy: true} = state, line) when line in @immediate, do: handle(state, line)

  defp input(%{busy: true} = state, line) do
    if line != :eof, do: info("(queued until the agent finishes; /stop halts it)")
    %{state | queue: :queue.in(line, state.queue)}
  end

  defp input(state, line), do: handle(state, line)

  defp event(state, event) do
    Enum.each(Render.event(event), &info/1)

    case event["type"] do
      "proposal" ->
        %{state | proposal: event}

      "run_finished" ->
        state = %{state | busy: false, outcome: event["outcome"]}
        status(state)
        state

      type when type in ["session_ended", "session_cancelled"] ->
        {:halt, :session_ended}

      _other ->
        state
    end
  end

  # ---------------------------------------------------------------------------
  # Commands
  # ---------------------------------------------------------------------------

  defp handle(_state, :eof), do: {:halt, :quit}
  defp handle(_state, "/quit"), do: {:halt, :quit}

  defp handle(state, "/help") do
    Enum.each(@help, &info/1)
    state
  end

  defp handle(state, "/spend") do
    cap = if state.spend_cap, do: " of the session cap #{Render.usd(state.spend_cap)}", else: ""
    info("[spend] #{Render.usd(spend(state.meter))}#{cap}")
    state
  end

  defp handle(%{busy: false} = state, "/stop") do
    info("Nothing is running.")
    state
  end

  defp handle(state, "/stop") do
    case Session.stop(state.pid, actor(state)) do
      :ok -> state
      {:error, reason} -> refused(state, "/stop", reason)
    end
  end

  defp handle(state, "/approve") do
    with_proposal(state, fn proposal ->
      case Session.approve_deviations(account(state), membership(state), proposal["proposal_id"]) do
        :ok -> info("Deviations approved: /confirm saves this Proposal.")
        {:error, reason} -> info("/approve refused: #{reason}")
      end

      state
    end)
  end

  defp handle(state, "/confirm") do
    with_proposal(state, fn proposal ->
      case Session.confirm(account(state), membership(state), proposal["proposal_id"]) do
        {:ok, summary} ->
          info("Confirmed: #{inspect(summary)}")
          {:halt, :confirmed}

        {:error, reason} ->
          refused(state, "/confirm", reason)
      end
    end)
  end

  defp handle(state, "/continue") do
    case Session.authorize_continuation(state.pid, membership(state)) do
      :ok -> %{state | busy: true}
      {:error, reason} -> refused(state, "/continue", reason)
    end
  end

  defp handle(state, "/" <> _unknown = line) do
    info("Unknown command #{line}; /help lists the commands.")
    state
  end

  defp handle(state, text) do
    case String.trim(text) do
      "" ->
        state

      text ->
        case Session.send_message(state.pid, text) do
          :ok ->
            %{state | busy: true}

          {:error, :authorization_required} ->
            refused(state, "message", "a limit was reached; /continue authorizes more")

          {:error, reason} ->
            refused(state, "message", reason)
        end
    end
  end

  defp with_proposal(state, fun) do
    case Session.current_proposal(state.pid) do
      nil ->
        info("No Proposal has been shown yet.")
        state

      proposal ->
        fun.(proposal)
    end
  end

  defp refused(state, what, reason) do
    info("#{what} refused: #{reason}")
    state
  end

  defp status(state) do
    proposal = Session.current_proposal(state.pid) || state.proposal
    info(Render.status_line(proposal, state.outcome, spend(state.meter)))
  end

  # ---------------------------------------------------------------------------
  # Session and input
  # ---------------------------------------------------------------------------

  defp attrs(household) do
    %{
      account_id: household.account_id,
      user_id: household.owner.user_id,
      membership_id: household.owner.membership_id,
      role: :owner,
      range: household.range,
      slots: household.slots
    }
  end

  # A chat killed without /quit (Ctrl-C) leaves its session row holding the
  # Household's slot until its lease ends; no process runs it any more.
  defp release_stale_session(household) do
    with nil <- Session.whereis(household.account_id),
         %{id: id} <- PlanningRepo.active_household_session(household.account_id) do
      _ = PlanningRepo.expire_session(household.account_id, id)
    end

    :ok
  end

  defp end_session(pid, household) do
    if Process.alive?(pid) do
      Session.cancel(pid, %{membership_id: household.owner.membership_id, owner?: true})
    end
  catch
    :exit, _reason -> :ok
  end

  defp start_reader(lines) when is_list(lines) do
    parent = self()

    spawn_link(fn ->
      Enum.each(lines, &send(parent, {:chat_input, &1}))
      send(parent, {:chat_input, :eof})
    end)
  end

  defp start_reader(:stdio) do
    parent = self()
    spawn_link(fn -> read_stdio(parent) end)
  end

  defp read_stdio(parent) do
    case IO.gets("") do
      line when is_binary(line) ->
        send(parent, {:chat_input, String.trim_trailing(line, "\n")})
        read_stdio(parent)

      _eof_or_error ->
        send(parent, {:chat_input, :eof})
    end
  end

  defp header(household) do
    {first, last} = household.range

    info("Planning chat: fictitious Household, 3 Members (one allergic to peanuts).")
    info("Range #{first} to #{last}, slots #{Enum.join(household.slots, ", ")}.")
    info("Type a message for the agent, or /help.")
  end

  defp start_hint(:range_already_planned),
    do: " (a confirmed plan covers the range; run with --reset to reseed)"

  defp start_hint(:session_already_active), do: " (run with --reset to reseed)"
  defp start_hint(_reason), do: ""

  defp spend(meter), do: Agent.get(meter, &Map.get(&1, :chat, 0))
  defp actor(state), do: %{membership_id: membership(state), owner?: true}
  defp account(state), do: state.household.account_id
  defp membership(state), do: state.household.owner.membership_id
  defp info(line), do: Mix.shell().info(line)
end
