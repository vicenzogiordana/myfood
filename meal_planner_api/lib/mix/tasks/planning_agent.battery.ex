defmodule Mix.Tasks.PlanningAgent.Battery do
  @moduledoc """
  Runs the planning agent's pre-launch quality battery (issue #109, spec
  #93): 15 tasks x 5 runs through the planning agent session module with
  the real model adapter, fictitious offline fixtures and prepared recipe
  and price responses, and writes a pass/fail report with per-run evidence.

      MIX_ENV=test mix planning_agent.battery --config battery.json [--out report.md]

  This command makes paid provider calls. It refuses to start without a
  configuration file holding the battery's spend ceiling and the #87
  deferred criteria, which are human decisions with no defaults (see
  `MealPlannerApi.PlanningAgent.Battery.Config` and
  `docs/QUALITY_BATTERY.md`).

  It runs only with `MIX_ENV=test`: every run builds its fixtures in a SQL
  sandbox that is rolled back, so the battery never writes real data. Use a
  migrated, empty database of its own (`MYFOOD_TEST_DATABASE`).

  ## Options

    * `--config PATH` — the JSON configuration (required)
    * `--out PATH` — where to write the report (default:
      `planning-agent-battery-<timestamp>.json` or `.md`, by
      `evidence_format`)

  ## Provider and optimizer environment

  The test environment never configures the paid adapter, so the command
  reads the same variables as `config/runtime.exs`: `OPENAI_API_KEY`,
  `PLANNING_AGENT_SPEND_CAP_MICROS`, `PLANNING_AGENT_TOKEN_CAP`,
  `OPENAI_INPUT_PRICE_MICROS_PER_MTOK`, `OPENAI_OUTPUT_PRICE_MICROS_PER_MTOK`
  and `PLANNING_AGENT_MAX_CONCURRENT_PROVIDER_CALLS`; the optimizer reads
  `PLANNING_AGENT_MAX_CONCURRENT_OPTIMIZER_RUNS`, `OPTIMIZER_PYTHON` and
  `OPTIMIZER_SCRIPT_PATH`. Missing caps make the adapter refuse to start.

  ## Exit status

  0 when the verdict is `pass`, 1 otherwise.
  """

  use Mix.Task

  alias MealPlannerApi.PlanningAgent.Battery
  alias MealPlannerApi.PlanningAgent.Battery.Report
  alias MealPlannerApi.PlanningAgent.Model.OpenAIResponses
  alias MealPlannerApi.PlanningAgent.Optimizer.Port

  @shortdoc "Runs the planning agent quality battery (paid provider calls)"

  @provider_env [
    {:api_key, "OPENAI_API_KEY", :string},
    {:spend_cap_micros, "PLANNING_AGENT_SPEND_CAP_MICROS", :integer},
    {:token_cap, "PLANNING_AGENT_TOKEN_CAP", :integer},
    {:input_price_micros_per_mtok, "OPENAI_INPUT_PRICE_MICROS_PER_MTOK", :integer},
    {:output_price_micros_per_mtok, "OPENAI_OUTPUT_PRICE_MICROS_PER_MTOK", :integer},
    {:max_concurrent_calls, "PLANNING_AGENT_MAX_CONCURRENT_PROVIDER_CALLS", :integer}
  ]

  @optimizer_env [
    {:max_concurrent_runs, "PLANNING_AGENT_MAX_CONCURRENT_OPTIMIZER_RUNS", :integer},
    {:python_executable, "OPTIMIZER_PYTHON", :string},
    {:script_path, "OPTIMIZER_SCRIPT_PATH", :string}
  ]

  @impl Mix.Task
  def run(args) do
    report = run(args, [])
    if report["summary"]["verdict"] != "pass", do: exit({:shutdown, 1})
  end

  @doc """
  Runs the command and returns the report. `overrides` replace the model
  (`:model`), the optimizer (`:optimizer`), the tasks, the runs per task or
  the environment (`:provider_env`), for offline tests only.
  """
  @spec run([String.t()], keyword()) :: map()
  def run(args, overrides) do
    {opts, _rest} = OptionParser.parse!(args, strict: [config: :string, out: :string])
    config_path = opts[:config] || Mix.raise(usage())
    config = read_config!(config_path)

    Mix.Task.run("app.start")

    env = Keyword.get_lazy(overrides, :provider_env, &System.get_env/0)

    battery_opts =
      [
        model: Keyword.get(overrides, :model, {OpenAIResponses, provider_opts(env)}),
        optimizer: Keyword.get(overrides, :optimizer, {Port, env_opts(@optimizer_env, env)}),
        on_run: &print_run/1
      ] ++ Keyword.take(overrides, [:tasks, :runs_per_task])

    case Battery.run(config, battery_opts) do
      {:ok, report} ->
        format = String.to_existing_atom(report["config"]["evidence_format"])
        out = opts[:out] || default_out(format)
        File.write!(out, Report.render(report, format))

        Mix.shell().info("Verdict: #{report["summary"]["verdict"]}")
        Enum.each(report["summary"]["verdict_reasons"], &Mix.shell().info("  - " <> &1))
        Mix.shell().info("Report written to #{out}")
        report

      {:error, reason} ->
        Mix.raise(refusal(reason))
    end
  end

  @doc "The paid adapter's options found in `env` (variables of `config/runtime.exs`)."
  @spec provider_opts(%{String.t() => String.t()}) :: keyword()
  def provider_opts(env), do: env_opts(@provider_env, env)

  defp env_opts(spec, env) do
    Enum.flat_map(spec, fn {key, name, kind} ->
      case parse(kind, Map.get(env, name)) do
        nil -> []
        value -> [{key, value}]
      end
    end)
  end

  defp parse(_kind, nil), do: nil

  defp parse(:string, value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp parse(:integer, value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} -> integer
      _ -> nil
    end
  end

  defp read_config!(path) do
    with {:ok, body} <- File.read(path),
         {:ok, config} <- Jason.decode(body) do
      config
    else
      {:error, %Jason.DecodeError{} = error} ->
        Mix.raise("battery configuration #{path} is not valid JSON: #{Exception.message(error)}")

      {:error, reason} ->
        Mix.raise("cannot read battery configuration #{path}: #{:file.format_error(reason)}")
    end
  end

  defp print_run(result) do
    violations =
      case result.grade.violations do
        [] -> ""
        list -> " violations=" <> Enum.map_join(list, ",", &Atom.to_string/1)
      end

    Mix.shell().info(
      "#{result.task_id} run #{result.run}: #{result.grade.outcome}#{violations} " <>
        "(#{result.latency_ms} ms, #{result.spend_micros} micro-USD)"
    )
  end

  defp default_out(format) do
    stamp = DateTime.utc_now() |> DateTime.to_iso8601(:basic) |> String.replace(~r/\W/, "")
    "planning-agent-battery-#{stamp}.#{if format == :json, do: "json", else: "md"}"
  end

  defp usage do
    "usage: mix planning_agent.battery --config PATH [--out PATH]. The configuration " <>
      "holds the battery's spend ceiling and the #87 deferred criteria; see " <>
      "docs/QUALITY_BATTERY.md"
  end

  defp refusal({:unconfigured, problems}) do
    "the battery refuses to start: its configuration is incomplete (human decisions " <>
      "with no defaults):\n  " <> Enum.join(problems, "\n  ")
  end

  defp refusal(:sandbox_required) do
    "the battery refuses to start: run it with MIX_ENV=test, where every run is " <>
      "rolled back in the SQL sandbox"
  end

  defp refusal(:catalog_not_empty) do
    "the battery refuses to start: the database already holds recipes; use an empty, " <>
      "migrated database (MYFOOD_TEST_DATABASE)"
  end

  defp refusal({:model_unconfigured, reason}),
    do: "the battery refuses to start: the model adapter refused to start: #{inspect(reason)}"

  defp refusal(reason), do: "the battery refuses to start: #{inspect(reason)}"
end
