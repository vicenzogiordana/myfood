defmodule MealPlannerApi.PlanningAgent.Model.OpenAIResponsesTest do
  @moduledoc """
  The OpenAI Responses adapter against a stubbed HTTP endpoint: mandatory
  spend and token caps, worst-case reservation before every call, settlement
  to actual usage after it.
  """

  use ExUnit.Case, async: true

  alias MealPlannerApi.PlanningAgent.CallBounds
  alias MealPlannerApi.PlanningAgent.Model.OpenAIResponses

  @stub __MODULE__

  @request %{
    instructions: "You are the culinary planning agent.",
    messages: [
      %{role: :user, content: "Plan something light"},
      %{role: :tool_call, id: "call_1", name: "search_recipes", arguments: %{"query" => "soup"}},
      %{role: :tool_result, id: "call_1", name: "search_recipes", content: %{"recipes" => []}}
    ],
    tools: [
      %{
        name: "search_recipes",
        description: "Search recipes",
        parameters: %{"type" => "object", "properties" => %{}}
      }
    ]
  }

  defp opts(overrides \\ []) do
    Keyword.merge(
      [
        api_key: "test-key",
        spend_cap_micros: 1_000_000,
        token_cap: 1_000_000,
        input_price_micros_per_mtok: 1_000_000,
        output_price_micros_per_mtok: 4_000_000,
        max_output_tokens: 1_000,
        req_options: [plug: {Req.Test, @stub}]
      ],
      overrides
    )
  end

  defp stub_response(body) do
    test = self()

    Req.Test.stub(@stub, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test, {:provider_called, conn, Jason.decode!(raw)})
      Req.Test.json(conn, body)
    end)
  end

  defp text_response(text, usage) do
    %{
      "output" => [
        %{"type" => "message", "content" => [%{"type" => "output_text", "text" => text}]}
      ],
      "usage" => usage
    }
  end

  describe "init/1" do
    test "refuses to run when the spend cap or the token cap is unset" do
      assert {:error, :spend_caps_unconfigured} =
               OpenAIResponses.init(opts(spend_cap_micros: nil))

      assert {:error, :spend_caps_unconfigured} = OpenAIResponses.init(opts(token_cap: nil))

      assert {:error, :spend_caps_unconfigured} =
               OpenAIResponses.init(opts(spend_cap_micros: nil, token_cap: nil))

      assert {:error, :spend_caps_unconfigured} = OpenAIResponses.init(opts(token_cap: 0))
    end

    test "refuses to run when prices are unknown, since spend could not be enforced" do
      assert {:error, :pricing_unconfigured} =
               OpenAIResponses.init(opts(output_price_micros_per_mtok: nil))
    end

    test "refuses to run without an API key" do
      assert {:error, :provider_unconfigured} = OpenAIResponses.init(opts(api_key: nil))
    end

    test "defaults to the single launch model" do
      {:ok, state} = OpenAIResponses.init(opts())
      assert state.config.model == "gpt-6.1-sol"
    end
  end

  describe "recovery" do
    test "keeps the spend of the Planning Session, never its credentials" do
      {:ok, state} = OpenAIResponses.init(opts())

      # A call was in flight when the server stopped: its reservation was
      # never settled, so its worst case stays spent.
      {:ok, ledger} =
        MealPlannerApi.PlanningAgent.SpendLedger.reserve(state.ledger, %{micros: 700, tokens: 70})

      state = %{state | ledger: %{ledger | spent_micros: 300, spent_tokens: 150}}

      saved = OpenAIResponses.recoverable(state)
      refute inspect(saved, limit: :infinity) =~ "test-key"

      assert {:ok, recovered} = OpenAIResponses.recover(opts(), saved)

      assert OpenAIResponses.spend(recovered) == %{
               spent_micros: 1_000,
               spent_tokens: 220,
               reserved_micros: 0,
               reserved_tokens: 0
             }

      assert recovered.config.api_key == "test-key"
    end

    test "still refuses without configured caps" do
      {:ok, state} = OpenAIResponses.init(opts())

      assert {:error, :spend_caps_unconfigured} =
               OpenAIResponses.recover(
                 opts(spend_cap_micros: nil),
                 OpenAIResponses.recoverable(state)
               )
    end
  end

  describe "respond/2" do
    test "sends one Responses API request and settles spend to actual usage" do
      stub_response(
        text_response("Here you go.", %{"input_tokens" => 100, "output_tokens" => 50})
      )

      {:ok, state} = OpenAIResponses.init(opts())

      assert {:ok, %{text: "Here you go.", tool_calls: [], usage: usage}, state} =
               OpenAIResponses.respond(state, @request)

      assert usage == %{input_tokens: 100, output_tokens: 50}

      assert_received {:provider_called, conn, body}
      assert conn.request_path == "/v1/responses"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-key"]
      assert body["model"] == "gpt-6.1-sol"
      assert body["instructions"] == @request.instructions
      assert body["max_output_tokens"] == 1_000
      assert body["store"] == false

      assert [
               %{"role" => "user", "content" => "Plan something light"},
               %{"type" => "function_call", "call_id" => "call_1", "name" => "search_recipes"} =
                 call,
               %{"type" => "function_call_output", "call_id" => "call_1", "output" => output}
             ] = body["input"]

      assert Jason.decode!(call["arguments"]) == %{"query" => "soup"}
      assert Jason.decode!(output) == %{"recipes" => []}
      assert [%{"type" => "function", "name" => "search_recipes"}] = body["tools"]

      # 100 input tokens at 1 USD/Mtok + 50 output tokens at 4 USD/Mtok = 300 micro-USD.
      assert OpenAIResponses.spend(state) == %{
               spent_micros: 300,
               spent_tokens: 150,
               reserved_micros: 0,
               reserved_tokens: 0
             }
    end

    test "parses tool calls" do
      stub_response(%{
        "output" => [
          %{
            "type" => "function_call",
            "call_id" => "call_9",
            "name" => "run_optimizer",
            "arguments" => ~s({"exclude_recipe_ids":[]})
          }
        ],
        "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
      })

      {:ok, state} = OpenAIResponses.init(opts())

      assert {:ok, %{tool_calls: [%{id: "call_9", name: "run_optimizer", arguments: args}]}, _} =
               OpenAIResponses.respond(state, @request)

      assert args == %{"exclude_recipe_ids" => []}
    end

    test "reserves the worst-case cost before calling and refuses when it exceeds the spend cap" do
      stub_response(text_response("never", %{"input_tokens" => 1, "output_tokens" => 1}))

      # Worst case output alone is 1_000 tokens at 4 USD/Mtok = 4_000 micro-USD.
      {:ok, state} = OpenAIResponses.init(opts(spend_cap_micros: 3_999))

      assert {:error, :spend_cap_reached, state} = OpenAIResponses.respond(state, @request)
      refute_received {:provider_called, _, _}
      assert OpenAIResponses.spend(state).spent_micros == 0
    end

    test "the cumulative token cap stops further calls" do
      stub_response(text_response("ok", %{"input_tokens" => 900, "output_tokens" => 600}))
      {:ok, state} = OpenAIResponses.init(opts(token_cap: 2_400))

      assert {:ok, _, state} = OpenAIResponses.respond(state, @request)
      assert_received {:provider_called, _, _}

      assert {:error, :token_cap_reached, _state} = OpenAIResponses.respond(state, @request)
      refute_received {:provider_called, _, _}
    end

    test "a provider failure is reported and keeps the worst case as spent" do
      Req.Test.stub(@stub, fn conn -> Plug.Conn.send_resp(conn, 503, "unavailable") end)
      {:ok, state} = OpenAIResponses.init(opts())

      assert {:error, :provider_unavailable, state} = OpenAIResponses.respond(state, @request)
      assert %{reserved_micros: 0, spent_micros: spent} = OpenAIResponses.spend(state)
      assert spent >= 4_000
    end

    for {status, reason} <- [
          {401, :provider_unauthorized},
          {403, :provider_unauthorized},
          {400, :provider_rejected_request},
          {404, :provider_rejected_request},
          {422, :provider_rejected_request},
          {409, :provider_conflict},
          {408, :provider_unavailable},
          {429, :provider_unavailable},
          {500, :provider_unavailable},
          {503, :provider_unavailable}
        ] do
      test "an HTTP #{status} is classified as #{reason}" do
        status = unquote(status)
        Req.Test.stub(@stub, fn conn -> Plug.Conn.send_resp(conn, status, "{}") end)
        {:ok, state} = OpenAIResponses.init(opts())

        assert {:error, unquote(reason), _state} = OpenAIResponses.respond(state, @request)
      end
    end

    test "a transport timeout is classified as a provider timeout" do
      Req.Test.stub(@stub, &Req.Test.transport_error(&1, :timeout))
      {:ok, state} = OpenAIResponses.init(opts())

      assert {:error, :provider_timeout, _state} = OpenAIResponses.respond(state, @request)
    end

    test "reasoning items never reach the response text" do
      stub_response(%{
        "output" => [
          %{
            "type" => "reasoning",
            "summary" => [%{"type" => "summary_text", "text" => "secret chain of thought"}]
          },
          %{"type" => "message", "content" => [%{"type" => "output_text", "text" => "Answer."}]}
        ],
        "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
      })

      {:ok, state} = OpenAIResponses.init(opts())

      assert {:ok, %{text: "Answer.", tool_calls: []}, _state} =
               OpenAIResponses.respond(state, @request)
    end

    test "a 200 response without usage keeps the reservation as spent" do
      stub_response(%{
        "output" => [
          %{"type" => "message", "content" => [%{"type" => "output_text", "text" => "hi"}]}
        ]
      })

      {:ok, state} = OpenAIResponses.init(opts())

      # Unknown usage is reported as unknown, never as zero tokens.
      assert {:ok, %{text: "hi", usage: nil}, state} = OpenAIResponses.respond(state, @request)
      assert %{reserved_micros: 0, spent_micros: spent} = OpenAIResponses.spend(state)
      # Worst case output alone is 1_000 tokens at 4 USD/Mtok = 4_000 micro-USD.
      assert spent >= 4_000
    end

    test "a 200 response with invalid token counts keeps the reservation as spent" do
      stub_response(text_response("hi", %{"input_tokens" => "100", "output_tokens" => "50"}))
      {:ok, state} = OpenAIResponses.init(opts())

      assert {:ok, %{text: "hi"}, state} = OpenAIResponses.respond(state, @request)
      assert %{reserved_micros: 0, spent_micros: spent} = OpenAIResponses.spend(state)
      assert spent >= 4_000
    end

    test "a 200 response with neither a message nor a tool call is an invalid provider response" do
      stub_response(%{
        "status" => "completed",
        "output" => [%{"type" => "reasoning", "summary" => []}],
        "usage" => %{"input_tokens" => 100, "output_tokens" => 50}
      })

      {:ok, state} = OpenAIResponses.init(opts())

      assert {:error, :invalid_provider_response, _state} =
               OpenAIResponses.respond(state, @request)
    end

    test "an incomplete 200 response is an invalid provider response, even with partial text" do
      stub_response(
        text_response("Here is your", %{"input_tokens" => 100, "output_tokens" => 50})
        |> Map.put("status", "incomplete")
        |> Map.put("incomplete_details", %{"reason" => "max_output_tokens"})
      )

      {:ok, state} = OpenAIResponses.init(opts())

      assert {:error, :invalid_provider_response, _state} =
               OpenAIResponses.respond(state, @request)
    end

    test "an incomplete response is not retried through the call bounds: billed once" do
      stub_response(
        text_response("Here is your", %{"input_tokens" => 100, "output_tokens" => 50})
        |> Map.put("status", "incomplete")
      )

      {:ok, state} = OpenAIResponses.init(opts())
      bounds = CallBounds.new(policies: %{model: %{timeout_ms: 1_000, backoff_ms: 1}})

      assert {:error, :invalid_provider_response, state} =
               CallBounds.run(bounds, :model, state, fn model_state, _call ->
                 OpenAIResponses.respond(model_state, @request)
               end)

      assert_received {:provider_called, _conn, _body}
      refute_received {:provider_called, _conn, _body}

      # One settlement: 100 input tokens at 1 USD/Mtok + 50 output tokens at
      # 4 USD/Mtok = 300 micro-USD.
      assert %{reserved_micros: 0, spent_micros: 300} = OpenAIResponses.spend(state)
    end

    test "reports the reserved state through the request checkpoint before calling" do
      test = self()

      Req.Test.stub(@stub, fn conn ->
        send(test, :provider_called)
        Req.Test.json(conn, text_response("ok", %{"input_tokens" => 1, "output_tokens" => 1}))
      end)

      {:ok, state} = OpenAIResponses.init(opts())
      checkpoint = fn model_state -> send(test, {:checkpoint, model_state}) end

      assert {:ok, _, _} =
               OpenAIResponses.respond(state, Map.put(@request, :checkpoint, checkpoint))

      assert_received {:checkpoint, reserved}
      assert OpenAIResponses.spend(reserved).reserved_micros >= 4_000
      assert_received :provider_called
    end
  end
end
