defmodule Mix.Tasks.PlanningAgent.Chat do
  @moduledoc """
  An interactive terminal chat with the production planning agent, over a
  fictitious Household (`MealPlannerApi.PlanningAgent.Chat.Household`).

      MIX_ENV=test MYFOOD_TEST_DATABASE=meal_planner_api_chat mix planning_agent.chat [--reset] [--scripted]

  It runs a real Planning Session (`MealPlannerApi.PlanningAgent.Session`)
  with the paid model adapter selected by `PLANNING_AGENT_MODEL_PROVIDER`
  (the same environment as `mix planning_agent.battery`, including the
  per-session spend and token caps) and the OR-Tools optimizer
  (`OPTIMIZER_PYTHON`). Live price lookups never reach the internet: the
  battery's prepared scraper answers them with no offers, so prices come
  from the seeded catalog.

  It runs only with `MIX_ENV=test`, like the battery, but unlike the
  battery it keeps its data: the database (`MYFOOD_TEST_DATABASE`) must be
  one of its own, never the shared test database, migrated beforehand.
  The first run seeds the Household; later runs reuse it. Run one chat per
  database at a time: a second chat on the same database takes the
  Household's session row from the first one.

  ## Options

    * `--reset` — empty the chat database and seed the Household again
      (needed after a confirmation, which plans the whole range); only a
      database whose name ends in `_chat`
    * `--scripted` — an offline scripted model and a greedy optimizer: no
      key, no spend, no Python

  See `docs/PLANNING_CHAT.md`.
  """

  use Mix.Task

  alias Ecto.Adapters.SQL.Sandbox
  alias MealPlannerApi.PlanningAgent.Chat.{Household, Repl, Scripted}
  alias MealPlannerApi.PlanningAgent.Optimizer.Port
  alias MealPlannerApi.Repo
  alias Mix.Tasks.PlanningAgent.Battery

  @shortdoc "Chats with the planning agent in the terminal (paid unless --scripted)"

  @shared_test_database "meal_planner_api_test"

  @optimizer_env [
    {:max_concurrent_runs, "PLANNING_AGENT_MAX_CONCURRENT_OPTIMIZER_RUNS"},
    {:python_executable, "OPTIMIZER_PYTHON"},
    {:script_path, "OPTIMIZER_SCRIPT_PATH"}
  ]

  @impl Mix.Task
  def run(args) do
    _ = run(args, [])
    :ok
  end

  @doc """
  Runs the chat and returns its outcome and spend. `overrides`, for tests
  only: `:sandboxed` (the caller owns a SQL sandbox, so the database is
  neither switched to persistent mode nor checked), `:input` (the lines to
  play) and `:household` (`Household.spec/1` overrides when seeding).
  """
  @spec run([String.t()], keyword()) :: map()
  def run(args, overrides) do
    {opts, _rest} = OptionParser.parse!(args, strict: [reset: :boolean, scripted: :boolean])

    Mix.Task.run("app.start")
    unless Keyword.get(overrides, :sandboxed, false), do: persistent_database!()

    if opts[:reset] do
      Household.reset!()
      Mix.shell().info("Chat database emptied.")
    end

    {seeded, household} = Household.ensure(Keyword.get(overrides, :household, []))
    Mix.shell().info("Household #{seeded}.")

    env = System.get_env()

    repl_opts =
      if opts[:scripted] do
        [model: Scripted.model(), optimizer: {Scripted, []}]
      else
        [
          model: Battery.provider_model(env),
          optimizer: {Port, optimizer_opts(env)},
          spend_cap_micros: Battery.provider_opts(env)[:spend_cap_micros]
        ]
      end

    repl_opts =
      case Keyword.fetch(overrides, :input) do
        {:ok, lines} -> Keyword.put(repl_opts, :input, lines)
        :error -> Keyword.put(repl_opts, :prompt, fn -> IO.write("you> ") end)
      end

    Repl.run(household, repl_opts)
  end

  # The chat keeps its data, so it leaves the sandbox's rollback mode and
  # refuses the shared test database.
  defp persistent_database! do
    config = Repo.config()

    if config[:pool] != Sandbox do
      Mix.raise("mix planning_agent.chat runs only with MIX_ENV=test (see docs/PLANNING_CHAT.md)")
    end

    if config[:database] == @shared_test_database do
      Mix.raise(
        "mix planning_agent.chat keeps its data: set MYFOOD_TEST_DATABASE to a database " <>
          "of its own (for example meal_planner_api_chat), never #{@shared_test_database}"
      )
    end

    # One shared, never-expiring owner outside a transaction: writes persist,
    # and long-lived processes (the Session, sweepers) are not disconnected
    # by the sandbox's ownership timeout.
    _owner =
      Sandbox.start_owner!(Repo, shared: true, sandbox: false, ownership_timeout: :infinity)

    :ok
  end

  defp optimizer_opts(env) do
    Enum.flat_map(@optimizer_env, fn {key, name} ->
      case env |> Map.get(name, "") |> String.trim() do
        "" -> []
        value when key == :max_concurrent_runs -> integer_opt(key, value)
        value -> [{key, value}]
      end
    end)
  end

  defp integer_opt(key, value) do
    case Integer.parse(value) do
      {integer, ""} -> [{key, integer}]
      _invalid -> []
    end
  end
end
