defmodule MealPlannerApi.PlanningAgent.Battery.MeteredModelTest do
  @moduledoc """
  The battery's spend meter around the real Claude Messages adapter, over a
  stubbed HTTP endpoint (no real Anthropic call; issue #144). A run is
  metered at what its calls settled from the reported usage; only a call
  whose outcome is unknown keeps its worst-case reservation metered.
  """

  use ExUnit.Case, async: true

  alias MealPlannerApi.PlanningAgent.Battery.MeteredModel
  alias MealPlannerApi.PlanningAgent.ConcurrencyLimiter
  alias MealPlannerApi.PlanningAgent.Model.ClaudeMessages

  @stub __MODULE__
  @run {"R1", 1}

  @request %{
    instructions: "You are the culinary planning agent.",
    messages: [%{role: :user, content: "Plan lunch and dinner from Monday to Wednesday"}],
    tools: [
      %{
        name: "search_recipes",
        description: "Search recipes",
        parameters: %{"type" => "object", "properties" => %{}}
      }
    ]
  }

  # The prices of the 2026-10-19 battery (issue #144), run on Opus with
  # refusal fallbacks on: cache write unset, so 1.25x input.
  defp claude_opts do
    [
      api_key: "test-key",
      model: "claude-opus-5-5",
      fallbacks: true,
      spend_cap_micros: 1_000_000,
      token_cap: 10_000_000,
      input_price_micros_per_mtok: 4_000_000,
      output_price_micros_per_mtok: 20_000_000,
      cache_read_price_micros_per_mtok: 200_000,
      fallback_input_price_micros_per_mtok: 5_000_000,
      fallback_output_price_micros_per_mtok: 25_000_000,
      # The worst case below includes one refusal fallback attempt.
      fallbacks: true,
      max_tokens: 16_000,
      max_concurrent_calls: 100,
      concurrency_limiter: start_limiter!(),
      req_options: [plug: {Req.Test, @stub}]
    ]
  end

  defp start_limiter! do
    name = :"limiter_#{System.unique_integer([:positive])}"
    start_supervised!({ConcurrencyLimiter, name: name})
    name
  end

  defp metered! do
    meter = start_supervised!({Agent, fn -> %{} end})

    {:ok, state} =
      MeteredModel.init(inner: {ClaudeMessages, claude_opts()}, meter: meter, run: @run)

    {meter, state}
  end

  defp metered(meter), do: Agent.get(meter, &Map.fetch!(&1, @run))

  defp stub_responses(bodies) do
    {:ok, queue} = Agent.start_link(fn -> bodies end)

    Req.Test.stub(@stub, fn conn ->
      body = Agent.get_and_update(queue, fn [next | rest] -> {next, rest} end)
      Req.Test.json(conn, body)
    end)
  end

  # A Messages API response body shaped like a real non-streaming answer of
  # Claude Opus 5.5 with prompt caching and `usage.iterations`.
  defp claude_message(content, stop_reason, usage) do
    %{
      "id" => "msg_01Fictitious",
      "type" => "message",
      "role" => "assistant",
      "model" => "claude-opus-5-5",
      "content" =>
        [%{"type" => "thinking", "thinking" => "", "signature" => "fictitious-signature"}] ++
          content,
      "stop_reason" => stop_reason,
      "stop_sequence" => nil,
      "stop_details" => nil,
      "usage" =>
        Map.merge(usage, %{
          "cache_creation" => %{
            "ephemeral_5m_input_tokens" => usage["cache_creation_input_tokens"],
            "ephemeral_1h_input_tokens" => 0
          },
          "server_tool_use" => nil,
          "service_tier" => "standard",
          "iterations" => [Map.put(usage, "type", "message")]
        })
    }
  end

  defp tool_turn do
    claude_message(
      [%{"type" => "tool_use", "id" => "toolu_01A", "name" => "search_recipes", "input" => %{}}],
      "tool_use",
      %{
        "input_tokens" => 2_134,
        "cache_creation_input_tokens" => 9_872,
        "cache_read_input_tokens" => 0,
        "output_tokens" => 412
      }
    )
  end

  defp final_turn do
    claude_message(
      [%{"type" => "text", "text" => "Here is your plan."}],
      "end_turn",
      %{
        "input_tokens" => 1_540,
        "cache_creation_input_tokens" => 1_203,
        "cache_read_input_tokens" => 9_872,
        "output_tokens" => 655
      }
    )
  end

  defp next_request(request) do
    Map.update!(request, :messages, fn messages ->
      messages ++
        [
          %{role: :tool_call, id: "toolu_01A", name: "search_recipes", arguments: %{}},
          %{role: :tool_result, id: "toolu_01A", name: "search_recipes", content: %{"n" => 0}}
        ]
    end)
  end

  test "meters a run at what its calls settled, not at a reservation open during a call" do
    stub_responses([tool_turn(), final_turn()])
    {meter, state} = metered!()
    test = self()
    checkpoint = fn metered_state -> send(test, {:checkpoint, metered_state}) end

    assert {:ok, %{tool_calls: [_]}, state} =
             MeteredModel.respond(state, Map.put(@request, :checkpoint, checkpoint))

    request = @request |> next_request() |> Map.put(:checkpoint, checkpoint)
    assert {:ok, %{text: "Here is your plan."}, state} = MeteredModel.respond(state, request)

    # Each call reserved its worst case (16_000 output tokens for the
    # requested model and one fallback attempt) before it was made.
    assert_received {:checkpoint, _first}
    assert_received {:checkpoint, second}
    assert ClaudeMessages.spend(second.inner).reserved_micros > 720_000

    # First call: 2_134 at 4 + 9_872 at 5 (cache write) + 412 at 20 USD/MTok
    # = 8_536 + 49_360 + 8_240 = 66_136 micro-USD. Second call: 1_540 at 4 +
    # 1_203 at 5 + 9_872 at 0.2 (cache read, rounded up) + 655 at 20 USD/MTok
    # = 6_160 + 6_015 + 1_975 + 13_100 = 27_250 micro-USD.
    assert %{spent_micros: 93_386, reserved_micros: 0} = ClaudeMessages.spend(state.inner)
    assert metered(meter) == 93_386
  end

  test "a failed call keeps its worst case metered" do
    Req.Test.stub(@stub, &Plug.Conn.send_resp(&1, 500, "{}"))
    {meter, state} = metered!()

    assert {:error, :provider_unavailable, state} = MeteredModel.respond(state, @request)

    %{spent_micros: spent, reserved_micros: 0} = ClaudeMessages.spend(state.inner)
    assert spent > 720_000
    assert metered(meter) == spent
  end

  test "a call killed mid-flight keeps its open reservation metered" do
    test = self()

    Req.Test.stub(@stub, fn conn ->
      send(test, :provider_called)
      Process.sleep(:infinity)
      conn
    end)

    {meter, state} = metered!()
    checkpoint = fn metered_state -> send(test, {:checkpoint, metered_state}) end

    task =
      Task.async(fn ->
        MeteredModel.respond(state, Map.put(@request, :checkpoint, checkpoint))
      end)

    assert_receive {:checkpoint, reserved}
    assert_receive :provider_called
    Task.shutdown(task, :brutal_kill)

    %{spent_micros: 0, reserved_micros: open} = ClaudeMessages.spend(reserved.inner)
    assert open > 720_000
    assert metered(meter) == open
  end
end
