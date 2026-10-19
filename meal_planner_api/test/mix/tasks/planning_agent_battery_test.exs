defmodule Mix.Tasks.PlanningAgent.BatteryTest do
  @moduledoc """
  The single battery command (issue #109), offline: it refuses without a
  configuration, without the spend ceiling and without a configured paid
  adapter, and writes the report in the configured evidence format.
  """

  use ExUnit.Case, async: false

  alias MealPlannerApi.PlanningAgent.{BatteryFixtures, BatteryOptimizer}
  alias MealPlannerApi.PlanningAgent.Model.{ClaudeMessages, OpenAIResponses, Scripted}
  alias Mix.Tasks.PlanningAgent.Battery

  @moduletag :tmp_dir

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    :ok
  end

  defp write_config!(dir, config) do
    path = Path.join(dir, "battery.json")
    File.write!(path, Jason.encode!(config))
    path
  end

  test "refuses without --config" do
    assert_raise Mix.Error, ~r/--config/, fn -> Battery.run([], []) end
  end

  test "refuses a configuration without a spend ceiling", %{tmp_dir: dir} do
    path = write_config!(dir, Map.delete(BatteryFixtures.config_map(), "spend_ceiling_micros"))

    assert_raise Mix.Error, ~r/spend_ceiling_micros: missing/, fn ->
      Battery.run(["--config", path], [])
    end
  end

  test "refuses when the paid adapter has no caps", %{tmp_dir: dir} do
    path = write_config!(dir, BatteryFixtures.config_map())

    assert_raise Mix.Error, ~r/model adapter refused to start: :spend_caps_unconfigured/, fn ->
      Battery.run(["--config", path], provider_env: %{})
    end
  end

  test "builds the paid adapter's options from the provider environment" do
    env = %{
      "OPENAI_API_KEY" => "fictitious-key",
      "PLANNING_AGENT_SPEND_CAP_MICROS" => "1000",
      "PLANNING_AGENT_TOKEN_CAP" => " 2000 ",
      "OPENAI_INPUT_PRICE_MICROS_PER_MTOK" => "not a number"
    }

    assert Battery.provider_opts(env) == [
             api_key: "fictitious-key",
             spend_cap_micros: 1_000,
             token_cap: 2_000
           ]
  end

  test "builds the Claude adapter when the provider environment selects it" do
    env = %{
      "PLANNING_AGENT_MODEL_PROVIDER" => "claude",
      "ANTHROPIC_API_KEY" => "fictitious-key",
      "PLANNING_AGENT_SPEND_CAP_MICROS" => "1000",
      "PLANNING_AGENT_TOKEN_CAP" => "2000",
      "ANTHROPIC_INPUT_PRICE_MICROS_PER_MTOK" => "4000000",
      "ANTHROPIC_OUTPUT_PRICE_MICROS_PER_MTOK" => "x",
      "ANTHROPIC_FALLBACK_INPUT_PRICE_MICROS_PER_MTOK" => "5000000",
      "PLANNING_AGENT_CLAUDE_EFFORT" => "high",
      "OPENAI_API_KEY" => "ignored"
    }

    assert Battery.provider_model(env) ==
             {ClaudeMessages,
              [
                api_key: "fictitious-key",
                spend_cap_micros: 1_000,
                token_cap: 2_000,
                input_price_micros_per_mtok: 4_000_000,
                fallback_input_price_micros_per_mtok: 5_000_000,
                effort: "high"
              ]}

    assert {OpenAIResponses, [api_key: "ignored"]} =
             Battery.provider_model(Map.delete(env, "PLANNING_AGENT_MODEL_PROVIDER"))
             |> then(fn {module, opts} -> {module, Keyword.take(opts, [:api_key])} end)
  end

  test "refuses an unwritable --out before any paid run starts", %{tmp_dir: dir} do
    path = write_config!(dir, BatteryFixtures.config_map())
    out = Path.join([dir, "missing", "dir", "report.md"])
    plan = [{:tool_calls, [{"run_optimizer", %{}}]}, {:tool_calls, [{"present_proposal", %{}}]}]

    assert_raise Mix.Error, ~r/cannot write the report/, fn ->
      Battery.run(["--config", path, "--out", out],
        model: fn _task, _run -> {Scripted, script: plan ++ [{:text, "Here is your plan."}]} end,
        optimizer: {BatteryOptimizer, []},
        tasks: Enum.take(MealPlannerApi.PlanningAgent.Battery.Tasks.all(), 1),
        runs_per_task: 1
      )
    end

    refute_received {:mix_shell, :info, ["R1 run 1: " <> _]}
  end

  test "refuses an --out that is an existing directory before any model call", %{tmp_dir: dir} do
    assert_out_refused_before_model_call(dir, dir, ~r/is a directory/)
  end

  test "refuses an --out that is an existing read-only file before any model call",
       %{tmp_dir: dir} do
    out = Path.join(dir, "report.md")
    File.write!(out, "")
    File.chmod!(out, 0o444)
    on_exit(fn -> File.chmod(out, 0o644) end)

    assert_out_refused_before_model_call(dir, out, ~r/is not writable/)
  end

  defp assert_out_refused_before_model_call(dir, out, message) do
    path = write_config!(dir, BatteryFixtures.config_map())
    test_pid = self()
    plan = [{:tool_calls, [{"run_optimizer", %{}}]}, {:tool_calls, [{"present_proposal", %{}}]}]

    model = fn _task, _run ->
      send(test_pid, :model_called)
      {Scripted, script: plan ++ [{:text, "Here is your plan."}]}
    end

    assert_raise Mix.Error, message, fn ->
      Battery.run(["--config", path, "--out", out],
        model: model,
        optimizer: {BatteryOptimizer, []},
        tasks: Enum.take(MealPlannerApi.PlanningAgent.Battery.Tasks.all(), 1),
        runs_per_task: 1
      )
    end

    refute_received :model_called
  end

  test "writes the report and prints the verdict", %{tmp_dir: dir} do
    config =
      BatteryFixtures.config_map()
      |> Map.put("evidence_format", "markdown")
      |> put_in(["thresholds", "max_latency_ms_p50"], 60_000)
      |> put_in(["thresholds", "max_latency_ms_p95"], 60_000)

    path = write_config!(dir, config)
    out = Path.join(dir, "report.md")
    plan = [{:tool_calls, [{"run_optimizer", %{}}]}, {:tool_calls, [{"present_proposal", %{}}]}]

    report =
      Battery.run(["--config", path, "--out", out],
        model: fn _task, _run -> {Scripted, script: plan ++ [{:text, "Here is your plan."}]} end,
        optimizer: {BatteryOptimizer, []},
        tasks: Enum.take(MealPlannerApi.PlanningAgent.Battery.Tasks.all(), 1),
        runs_per_task: 1
      )

    assert report["summary"]["runs"] == 1
    assert File.read!(out) =~ "# Planning agent quality battery"
    assert_received {:mix_shell, :info, ["R1 run 1: " <> _]}
    assert_received {:mix_shell, :info, ["Verdict: " <> _]}
    assert_received {:mix_shell, :info, ["Report written to " <> ^out]}
  end
end
