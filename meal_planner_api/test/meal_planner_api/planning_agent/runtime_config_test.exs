defmodule MealPlannerApi.PlanningAgent.RuntimeConfigTest do
  @moduledoc """
  `config/runtime.exs` reads the planning agent caps, prices and aggregate
  limits from the environment (issue #118). A malformed value never raises
  at boot: it reads as unset, so paid execution is refused instead.
  """

  use ExUnit.Case, async: false

  alias MealPlannerApi.PlanningAgent.Model.OpenAIResponses
  alias MealPlannerApi.PlanningAgent.Optimizer.Port, as: PortOptimizer

  @runtime Path.expand("../../../config/runtime.exs", __DIR__)

  @variables ~w(PLANNING_AGENT_SPEND_CAP_MICROS PLANNING_AGENT_TOKEN_CAP
                OPENAI_INPUT_PRICE_MICROS_PER_MTOK OPENAI_OUTPUT_PRICE_MICROS_PER_MTOK
                PLANNING_AGENT_MAX_CONCURRENT_PROVIDER_CALLS
                PLANNING_AGENT_MAX_CONCURRENT_OPTIMIZER_RUNS
                PLANNING_AGENT_SESSION_STARTS_PER_WINDOW
                PLANNING_AGENT_SESSION_START_WINDOW_SECONDS
                OPENAI_API_KEY AI_CLIENT)

  @valid %{
    "OPENAI_API_KEY" => "fictitious-key",
    "PLANNING_AGENT_SPEND_CAP_MICROS" => "2000000",
    "PLANNING_AGENT_TOKEN_CAP" => " 500000 ",
    "OPENAI_INPUT_PRICE_MICROS_PER_MTOK" => "1000000",
    "OPENAI_OUTPUT_PRICE_MICROS_PER_MTOK" => "4000000",
    "PLANNING_AGENT_MAX_CONCURRENT_PROVIDER_CALLS" => "8",
    "PLANNING_AGENT_MAX_CONCURRENT_OPTIMIZER_RUNS" => "2",
    "PLANNING_AGENT_SESSION_STARTS_PER_WINDOW" => "5",
    "PLANNING_AGENT_SESSION_START_WINDOW_SECONDS" => "3600"
  }

  setup do
    previous = Map.new(@variables, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    :ok
  end

  # Evaluates runtime.exs as a non-test environment with exactly `env` set.
  defp read_runtime(env) do
    Enum.each(@variables, &System.delete_env/1)
    # runtime.exs forbids the mock AI client outside the test environment.
    System.put_env("AI_CLIENT", "gemini")
    System.put_env(env)

    @runtime |> Config.Reader.read!(env: :dev, target: :host) |> Keyword.fetch!(:meal_planner_api)
  end

  test "valid values are read as integers" do
    config = read_runtime(@valid)

    adapter = Keyword.fetch!(config, OpenAIResponses)
    assert adapter[:spend_cap_micros] == 2_000_000
    assert adapter[:token_cap] == 500_000
    assert adapter[:input_price_micros_per_mtok] == 1_000_000
    assert adapter[:output_price_micros_per_mtok] == 4_000_000
    assert adapter[:max_concurrent_calls] == 8

    assert Keyword.fetch!(config, PortOptimizer)[:max_concurrent_runs] == 2
    assert Keyword.fetch!(config, :planning_agent)[:session_start_limit] == {5, 3_600}

    assert {:ok, _state} = OpenAIResponses.init(adapter)
  end

  for {name, malformed} <- [
        {"PLANNING_AGENT_SPEND_CAP_MICROS", "12abc"},
        {"PLANNING_AGENT_TOKEN_CAP", "lots"},
        {"PLANNING_AGENT_MAX_CONCURRENT_PROVIDER_CALLS", "4.5"},
        {"PLANNING_AGENT_SPEND_CAP_MICROS", "   "}
      ] do
    test "a malformed #{name} (#{inspect(malformed)}) does not crash boot and refuses as unconfigured" do
      config = read_runtime(Map.put(@valid, unquote(name), unquote(malformed)))
      adapter = Keyword.fetch!(config, OpenAIResponses)

      assert {:error, :spend_caps_unconfigured} = OpenAIResponses.init(adapter)
    end
  end

  test "a malformed price does not crash boot and leaves paid execution refused" do
    config = read_runtime(Map.put(@valid, "OPENAI_INPUT_PRICE_MICROS_PER_MTOK", "1e6"))
    adapter = Keyword.fetch!(config, OpenAIResponses)

    assert adapter[:input_price_micros_per_mtok] == nil
    assert {:error, :pricing_unconfigured} = OpenAIResponses.init(adapter)

    config =
      read_runtime(
        @valid
        |> Map.put("OPENAI_OUTPUT_PRICE_MICROS_PER_MTOK", "four")
        |> Map.put("PLANNING_AGENT_TOKEN_CAP", "x")
      )

    assert {:error, :spend_caps_unconfigured} =
             OpenAIResponses.init(Keyword.fetch!(config, OpenAIResponses))
  end

  test "a malformed or partial start rate limit reads as unset" do
    for overrides <- [
          %{"PLANNING_AGENT_SESSION_STARTS_PER_WINDOW" => "five"},
          %{"PLANNING_AGENT_SESSION_START_WINDOW_SECONDS" => "1h"},
          %{"PLANNING_AGENT_SESSION_START_WINDOW_SECONDS" => ""}
        ] do
      config = read_runtime(Map.merge(@valid, overrides))
      assert Keyword.fetch!(config, :planning_agent)[:session_start_limit] == nil
    end
  end

  test "a malformed optimizer cap reads as unset" do
    config = read_runtime(Map.put(@valid, "PLANNING_AGENT_MAX_CONCURRENT_OPTIMIZER_RUNS", "two"))
    assert Keyword.fetch!(config, PortOptimizer)[:max_concurrent_runs] == nil
  end

  test "without any variable every cap and limit is unset" do
    config = read_runtime(%{})

    adapter = Keyword.fetch!(config, OpenAIResponses)
    assert adapter[:spend_cap_micros] == nil
    assert adapter[:max_concurrent_calls] == nil
    assert Keyword.fetch!(config, PortOptimizer)[:max_concurrent_runs] == nil
    assert Keyword.fetch!(config, :planning_agent)[:session_start_limit] == nil
  end
end
