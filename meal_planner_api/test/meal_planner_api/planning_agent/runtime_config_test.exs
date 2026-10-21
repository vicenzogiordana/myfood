defmodule MealPlannerApi.PlanningAgent.RuntimeConfigTest do
  @moduledoc """
  `config/runtime.exs` reads the planning agent caps, prices and aggregate
  limits from the environment (issue #118). A malformed value never raises
  at boot: it reads as unset, so paid execution is refused instead.
  """

  use ExUnit.Case, async: false

  alias MealPlannerApi.PlanningAgent.Model.{ClaudeMessages, OpenAIResponses}
  alias MealPlannerApi.PlanningAgent.Optimizer.Port, as: PortOptimizer

  @runtime Path.expand("../../../config/runtime.exs", __DIR__)

  @variables ~w(PLANNING_AGENT_SPEND_CAP_MICROS PLANNING_AGENT_TOKEN_CAP
                OPENAI_INPUT_PRICE_MICROS_PER_MTOK OPENAI_OUTPUT_PRICE_MICROS_PER_MTOK
                PLANNING_AGENT_MAX_CONCURRENT_PROVIDER_CALLS
                PLANNING_AGENT_MAX_CONCURRENT_OPTIMIZER_RUNS
                PLANNING_AGENT_SESSION_STARTS_PER_WINDOW
                PLANNING_AGENT_SESSION_START_WINDOW_SECONDS
                OPENAI_API_KEY AI_CLIENT PLANNING_AGENT_MODEL_PROVIDER
                ANTHROPIC_API_KEY ANTHROPIC_INPUT_PRICE_MICROS_PER_MTOK
                ANTHROPIC_OUTPUT_PRICE_MICROS_PER_MTOK
                ANTHROPIC_CACHE_WRITE_PRICE_MICROS_PER_MTOK
                ANTHROPIC_CACHE_READ_PRICE_MICROS_PER_MTOK
                ANTHROPIC_FALLBACK_INPUT_PRICE_MICROS_PER_MTOK
                ANTHROPIC_FALLBACK_OUTPUT_PRICE_MICROS_PER_MTOK
                PLANNING_AGENT_CLAUDE_MODEL PLANNING_AGENT_CLAUDE_EFFORT
                PLANNING_AGENT_CLAUDE_FALLBACKS)

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

  @claude %{
    "PLANNING_AGENT_MODEL_PROVIDER" => " Claude ",
    "ANTHROPIC_API_KEY" => "fictitious-anthropic-key",
    "ANTHROPIC_INPUT_PRICE_MICROS_PER_MTOK" => "4000000",
    "ANTHROPIC_OUTPUT_PRICE_MICROS_PER_MTOK" => "20000000",
    "ANTHROPIC_FALLBACK_INPUT_PRICE_MICROS_PER_MTOK" => "5000000",
    "ANTHROPIC_FALLBACK_OUTPUT_PRICE_MICROS_PER_MTOK" => "25000000"
  }

  test "the OpenAI adapter is the provider unless Claude is selected" do
    for provider <- [nil, "openai", "something else"] do
      env =
        if provider, do: Map.put(@valid, "PLANNING_AGENT_MODEL_PROVIDER", provider), else: @valid

      config = read_runtime(env)
      assert Keyword.fetch!(config, :planning_agent)[:model] == {OpenAIResponses, []}
    end
  end

  test "PLANNING_AGENT_MODEL_PROVIDER=claude selects the Claude adapter with its variables" do
    config = read_runtime(Map.merge(@valid, @claude))

    assert Keyword.fetch!(config, :planning_agent)[:model] == {ClaudeMessages, []}

    adapter = Keyword.fetch!(config, ClaudeMessages)
    assert adapter[:api_key] == "fictitious-anthropic-key"
    assert adapter[:spend_cap_micros] == 2_000_000
    assert adapter[:token_cap] == 500_000
    assert adapter[:max_concurrent_calls] == 8
    assert adapter[:input_price_micros_per_mtok] == 4_000_000
    assert adapter[:output_price_micros_per_mtok] == 20_000_000
    assert adapter[:fallback_input_price_micros_per_mtok] == 5_000_000
    assert adapter[:fallback_output_price_micros_per_mtok] == 25_000_000
    # Unset model and effort keep the adapter defaults.
    refute Keyword.has_key?(adapter, :model)
    refute Keyword.has_key?(adapter, :effort)

    assert {:ok, state} = ClaudeMessages.init(adapter)
    assert state.config.model == "claude-haiku-5-5"
    assert state.config.effort == "medium"
  end

  test "the Claude model, effort and cache prices are read from the environment" do
    config =
      read_runtime(
        Map.merge(@valid, @claude)
        |> Map.put("PLANNING_AGENT_CLAUDE_MODEL", "claude-sonnet-5-5")
        |> Map.put("PLANNING_AGENT_CLAUDE_EFFORT", "low")
        |> Map.put("ANTHROPIC_CACHE_WRITE_PRICE_MICROS_PER_MTOK", "5000000")
        |> Map.put("ANTHROPIC_CACHE_READ_PRICE_MICROS_PER_MTOK", "200000")
      )

    adapter = Keyword.fetch!(config, ClaudeMessages)
    assert adapter[:model] == "claude-sonnet-5-5"
    assert adapter[:effort] == "low"
    assert adapter[:cache_write_price_micros_per_mtok] == 5_000_000
    assert adapter[:cache_read_price_micros_per_mtok] == 200_000
  end

  test "refusal fallbacks are off by default and can be turned on for models that accept them" do
    for {value, expected} <- [{"true", true}, {"false", false}] do
      config =
        read_runtime(
          Map.merge(@valid, @claude)
          |> Map.put("PLANNING_AGENT_CLAUDE_FALLBACKS", value)
        )

      assert Keyword.fetch!(config, ClaudeMessages)[:fallbacks] == expected
    end

    for unset <- [nil, "maybe"] do
      env = Map.merge(@valid, @claude)
      env = if unset, do: Map.put(env, "PLANNING_AGENT_CLAUDE_FALLBACKS", unset), else: env
      adapter = Keyword.fetch!(read_runtime(env), ClaudeMessages)
      refute Keyword.has_key?(adapter, :fallbacks)
      assert {:ok, state} = ClaudeMessages.init(adapter)
      assert state.config.fallbacks == false
    end
  end

  test "a malformed Claude price leaves paid execution refused" do
    config =
      read_runtime(
        Map.merge(@valid, @claude)
        |> Map.put("PLANNING_AGENT_CLAUDE_FALLBACKS", "true")
        |> Map.put("ANTHROPIC_FALLBACK_OUTPUT_PRICE_MICROS_PER_MTOK", "25e6")
      )

    assert {:error, :pricing_unconfigured} =
             ClaudeMessages.init(Keyword.fetch!(config, ClaudeMessages))
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
