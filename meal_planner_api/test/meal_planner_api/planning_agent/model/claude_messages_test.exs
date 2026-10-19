defmodule MealPlannerApi.PlanningAgent.Model.ClaudeMessagesTest do
  @moduledoc """
  The Claude Messages adapter against a stubbed HTTP endpoint (no real
  Anthropic call): the same contract as the OpenAI adapter (mandatory caps,
  worst-case reservation, settlement to usage, typed failures) plus the
  Claude specifics: tool_use / tool_result blocks, preserved assistant
  content blocks, cache and fallback usage, and typed stop reasons.
  """

  use ExUnit.Case, async: true

  alias MealPlannerApi.PlanningAgent.Allowance
  alias MealPlannerApi.PlanningAgent.CallBounds
  alias MealPlannerApi.PlanningAgent.ConcurrencyLimiter
  alias MealPlannerApi.PlanningAgent.Loop
  alias MealPlannerApi.PlanningAgent.Model.ClaudeMessages
  alias MealPlannerApi.PlanningAgent.SpendLedger

  @stub __MODULE__

  defmodule SlowProvider do
    @moduledoc false
    @behaviour Plug

    @impl true
    def init(opts), do: opts

    @impl true
    def call(conn, opts) do
      send(opts[:test], {:slow_provider_called, System.monotonic_time(:millisecond)})
      Process.sleep(opts[:delay_ms])
      Plug.Conn.send_resp(conn, 200, "{}")
    end
  end

  @tools [
    %{
      name: "search_recipes",
      description: "Search recipes",
      parameters: %{"type" => "object", "properties" => %{}}
    }
  ]

  @request %{
    instructions: "You are the culinary planning agent.",
    messages: [
      %{role: :user, content: "Plan something light"},
      %{role: :tool_call, id: "toolu_1", name: "search_recipes", arguments: %{"query" => "soup"}},
      %{
        role: :tool_call,
        id: "toolu_2",
        name: "search_recipes",
        arguments: %{"query" => "salad"}
      },
      %{role: :tool_result, id: "toolu_1", name: "search_recipes", content: %{"recipes" => []}},
      %{role: :tool_result, id: "toolu_2", name: "search_recipes", content: %{"recipes" => [1]}}
    ],
    tools: @tools
  }

  @thinking %{"type" => "thinking", "thinking" => "", "signature" => "fictitious-signature-1"}

  defp opts(overrides \\ []) do
    Keyword.merge(
      [
        api_key: "test-key",
        spend_cap_micros: 1_000_000,
        token_cap: 1_000_000,
        input_price_micros_per_mtok: 1_000_000,
        output_price_micros_per_mtok: 4_000_000,
        cache_write_price_micros_per_mtok: 1_250_000,
        cache_read_price_micros_per_mtok: 100_000,
        fallback_input_price_micros_per_mtok: 2_000_000,
        fallback_output_price_micros_per_mtok: 8_000_000,
        max_tokens: 1_000,
        max_concurrent_calls: 100,
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

  # Answers each call with the next body, in order.
  defp stub_responses(bodies) do
    test = self()
    {:ok, queue} = Agent.start_link(fn -> bodies end)

    Req.Test.stub(@stub, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test, {:provider_called, conn, Jason.decode!(raw)})
      body = Agent.get_and_update(queue, fn [next | rest] -> {next, rest} end)
      Req.Test.json(conn, body)
    end)
  end

  defp message(content, stop_reason, usage) do
    %{
      "id" => "msg_fictitious",
      "type" => "message",
      "role" => "assistant",
      "model" => "claude-opus-5-5",
      "content" => content,
      "stop_reason" => stop_reason,
      "stop_details" => nil,
      "usage" => usage
    }
  end

  defp text_response(text, usage \\ %{"input_tokens" => 1, "output_tokens" => 1}),
    do: message([@thinking, %{"type" => "text", "text" => text}], "end_turn", usage)

  defp start_limiter! do
    name = :"limiter_#{System.unique_integer([:positive])}"
    start_supervised!({ConcurrencyLimiter, name: name})
    name
  end

  defp hold_provider_slot!(limiter) do
    test = self()

    pid =
      spawn(fn ->
        ConcurrencyLimiter.run(limiter, :provider_calls, 1, fn ->
          send(test, :holding)
          Process.sleep(:infinity)
        end)
      end)

    assert_receive :holding
    pid
  end

  defp wait_until_free(limiter) do
    if ConcurrencyLimiter.in_use(limiter, :provider_calls) > 0 do
      Process.sleep(5)
      wait_until_free(limiter)
    end
  end

  describe "init/1" do
    test "refuses to run when the spend cap or the token cap is unset" do
      assert {:error, :spend_caps_unconfigured} = ClaudeMessages.init(opts(spend_cap_micros: nil))
      assert {:error, :spend_caps_unconfigured} = ClaudeMessages.init(opts(token_cap: nil))
      assert {:error, :spend_caps_unconfigured} = ClaudeMessages.init(opts(token_cap: 0))
    end

    test "refuses to run when the global provider concurrency cap is unset or invalid" do
      for cap <- [nil, 0, -1, "4"] do
        assert {:error, :spend_caps_unconfigured} =
                 ClaudeMessages.init(opts(max_concurrent_calls: cap))
      end
    end

    test "refuses to run when prices are unknown, since spend could not be enforced" do
      for key <- [
            :input_price_micros_per_mtok,
            :output_price_micros_per_mtok,
            :fallback_input_price_micros_per_mtok,
            :fallback_output_price_micros_per_mtok
          ] do
        assert {:error, :pricing_unconfigured} = ClaudeMessages.init(opts([{key, nil}]))
      end

      assert {:error, :pricing_unconfigured} = ClaudeMessages.init(opts(max_tokens: 0))
    end

    test "fallback prices are needed only when refusal fallbacks are on" do
      assert {:ok, _state} =
               ClaudeMessages.init(
                 opts(
                   fallbacks: false,
                   fallback_input_price_micros_per_mtok: nil,
                   fallback_output_price_micros_per_mtok: nil
                 )
               )
    end

    test "cache prices default to conservative multiples of the input price" do
      {:ok, state} =
        ClaudeMessages.init(
          opts(cache_write_price_micros_per_mtok: nil, cache_read_price_micros_per_mtok: nil)
        )

      # 5-minute cache writes cost 1.25x input; a read is counted at the full
      # input price, never below what it costs.
      assert state.config.cache_write_price_micros_per_mtok == 1_250_000
      assert state.config.cache_read_price_micros_per_mtok == 1_000_000
    end

    test "refuses to run without an API key" do
      assert {:error, :provider_unconfigured} = ClaudeMessages.init(opts(api_key: nil))
      assert {:error, :provider_unconfigured} = ClaudeMessages.init(opts(api_key: ""))
    end

    test "refuses an unknown effort level" do
      assert {:error, :provider_unconfigured} = ClaudeMessages.init(opts(effort: "huge"))
    end

    test "defaults to Claude Opus 5.5 at medium effort" do
      {:ok, state} = ClaudeMessages.init(opts())
      assert state.config.model == "claude-opus-5-5"
      assert state.config.effort == "medium"
    end
  end

  describe "recovery" do
    test "keeps the spend of the Planning Session, never its credentials" do
      {:ok, state} = ClaudeMessages.init(opts())
      {:ok, ledger} = SpendLedger.reserve(state.ledger, %{micros: 700, tokens: 70})
      state = %{state | ledger: %{ledger | spent_micros: 300, spent_tokens: 150}}

      saved = ClaudeMessages.recoverable(state)
      refute inspect(saved, limit: :infinity) =~ "test-key"

      assert {:ok, recovered} = ClaudeMessages.recover(opts(), saved)

      assert ClaudeMessages.spend(recovered) == %{
               spent_micros: 1_000,
               spent_tokens: 220,
               reserved_micros: 0,
               reserved_tokens: 0
             }

      assert recovered.config.api_key == "test-key"
    end

    test "still refuses without configured caps" do
      {:ok, state} = ClaudeMessages.init(opts())

      assert {:error, :spend_caps_unconfigured} =
               ClaudeMessages.recover(
                 opts(spend_cap_micros: nil),
                 ClaudeMessages.recoverable(state)
               )
    end
  end

  describe "respond/2 request" do
    test "sends one Messages API request and settles spend to actual usage" do
      stub_response(
        text_response("Here you go.", %{"input_tokens" => 100, "output_tokens" => 50})
      )

      {:ok, state} = ClaudeMessages.init(opts())

      assert {:ok, %{text: "Here you go.", tool_calls: [], usage: usage}, state} =
               ClaudeMessages.respond(state, @request)

      assert usage == %{input_tokens: 100, output_tokens: 50}

      assert_received {:provider_called, conn, body}
      assert conn.request_path == "/v1/messages"
      assert Plug.Conn.get_req_header(conn, "x-api-key") == ["test-key"]
      assert Plug.Conn.get_req_header(conn, "anthropic-version") == ["2023-06-01"]

      assert Plug.Conn.get_req_header(conn, "anthropic-beta") == [
               "server-side-fallback-2026-07-01"
             ]

      assert body["model"] == "claude-opus-5-5"
      assert body["max_tokens"] == 1_000
      assert body["thinking"] == %{"type" => "adaptive"}
      assert body["output_config"] == %{"effort" => "medium"}
      assert body["tool_choice"] == %{"type" => "auto"}
      assert body["fallbacks"] == "default"

      # The stable prefix (tools, then instructions) ends in a cache
      # breakpoint; the growing conversation is cached automatically.
      assert body["system"] == [
               %{
                 "type" => "text",
                 "text" => @request.instructions,
                 "cache_control" => %{"type" => "ephemeral"}
               }
             ]

      assert body["cache_control"] == %{"type" => "ephemeral"}

      assert body["tools"] == [
               %{
                 "name" => "search_recipes",
                 "description" => "Search recipes",
                 "input_schema" => %{"type" => "object", "properties" => %{}}
               }
             ]

      for forbidden <- ~w(temperature top_p top_k stop_sequences) do
        refute Map.has_key?(body, forbidden)
      end

      refute inspect(body) =~ "budget_tokens"

      # 100 input tokens at 1 USD/Mtok + 50 output tokens at 4 USD/Mtok = 300 micro-USD.
      assert ClaudeMessages.spend(state) == %{
               spent_micros: 300,
               spent_tokens: 150,
               reserved_micros: 0,
               reserved_tokens: 0
             }
    end

    test "tool calls and every tool result of a turn travel as blocks, results in one user message" do
      stub_response(text_response("ok"))
      {:ok, state} = ClaudeMessages.init(opts())

      assert {:ok, _, _} = ClaudeMessages.respond(state, @request)
      assert_received {:provider_called, _conn, body}

      assert [
               %{
                 "role" => "user",
                 "content" => [%{"type" => "text", "text" => "Plan something light"}]
               },
               %{"role" => "assistant", "content" => calls},
               %{"role" => "user", "content" => results}
             ] = body["messages"]

      assert calls == [
               %{
                 "type" => "tool_use",
                 "id" => "toolu_1",
                 "name" => "search_recipes",
                 "input" => %{"query" => "soup"}
               },
               %{
                 "type" => "tool_use",
                 "id" => "toolu_2",
                 "name" => "search_recipes",
                 "input" => %{"query" => "salad"}
               }
             ]

      assert [
               %{"type" => "tool_result", "tool_use_id" => "toolu_1", "content" => first},
               %{"type" => "tool_result", "tool_use_id" => "toolu_2", "content" => second}
             ] = results

      assert Jason.decode!(first) == %{"recipes" => []}
      assert Jason.decode!(second) == %{"recipes" => [1]}
    end

    test "without refusal fallbacks neither the parameter nor its beta is sent" do
      stub_response(text_response("ok"))
      {:ok, state} = ClaudeMessages.init(opts(fallbacks: false))

      assert {:ok, _, _} = ClaudeMessages.respond(state, @request)
      assert_received {:provider_called, conn, body}
      refute Map.has_key?(body, "fallbacks")
      assert Plug.Conn.get_req_header(conn, "anthropic-beta") == []
    end

    test "the model and effort are configurable" do
      stub_response(text_response("ok"))
      {:ok, state} = ClaudeMessages.init(opts(model: "claude-sonnet-5-5", effort: "low"))

      assert {:ok, _, _} = ClaudeMessages.respond(state, @request)
      assert_received {:provider_called, _conn, body}
      assert body["model"] == "claude-sonnet-5-5"
      assert body["output_config"] == %{"effort" => "low"}
    end
  end

  describe "respond/2 response" do
    test "parses tool_use blocks into neutral tool calls" do
      stub_response(
        message(
          [
            @thinking,
            %{
              "type" => "tool_use",
              "id" => "toolu_9",
              "name" => "run_optimizer",
              "input" => %{"exclude_recipe_ids" => []}
            },
            %{"type" => "tool_use", "id" => "toolu_10", "name" => "get_workspace", "input" => %{}}
          ],
          "tool_use",
          %{"input_tokens" => 10, "output_tokens" => 5}
        )
      )

      {:ok, state} = ClaudeMessages.init(opts())

      assert {:ok, %{text: nil, tool_calls: calls}, _} = ClaudeMessages.respond(state, @request)

      assert calls == [
               %{id: "toolu_9", name: "run_optimizer", arguments: %{"exclude_recipe_ids" => []}},
               %{id: "toolu_10", name: "get_workspace", arguments: %{}}
             ]
    end

    test "thinking blocks never reach the response text" do
      stub_response(
        message(
          [
            %{"type" => "thinking", "thinking" => "secret", "signature" => "s"},
            %{"type" => "text", "text" => "Answer."}
          ],
          "end_turn",
          %{"input_tokens" => 10, "output_tokens" => 5}
        )
      )

      {:ok, state} = ClaudeMessages.init(opts())

      assert {:ok, %{text: "Answer.", tool_calls: []}, _} =
               ClaudeMessages.respond(state, @request)
    end

    test "assistant content blocks are resent unchanged on later requests and survive recovery" do
      tool_turn = [
        @thinking,
        %{"type" => "text", "text" => "Let me look."},
        %{"type" => "tool_use", "id" => "toolu_a", "name" => "search_recipes", "input" => %{}}
      ]

      text_turn = [
        %{"type" => "thinking", "thinking" => "", "signature" => "fictitious-signature-2"},
        %{"type" => "text", "text" => "Here is a plan."}
      ]

      stub_responses([
        message(tool_turn, "tool_use", %{"input_tokens" => 10, "output_tokens" => 5}),
        message(text_turn, "end_turn", %{"input_tokens" => 10, "output_tokens" => 5}),
        text_response("Done.")
      ])

      first = %{instructions: "i", tools: @tools, messages: [%{role: :user, content: "Plan"}]}
      {:ok, state} = ClaudeMessages.init(opts())
      assert {:ok, %{tool_calls: [call]}, state} = ClaudeMessages.respond(state, first)
      assert_received {:provider_called, _, _}

      # What the planning loop appends after a tool call turn.
      second = %{
        first
        | messages:
            first.messages ++
              [
                %{role: :tool_call, id: call.id, name: call.name, arguments: call.arguments},
                %{role: :tool_result, id: call.id, name: call.name, content: %{"recipes" => []}}
              ]
      }

      assert {:ok, %{text: "Here is a plan."}, state} = ClaudeMessages.respond(state, second)
      assert_received {:provider_called, _, body}
      assert Enum.at(body["messages"], 1) == %{"role" => "assistant", "content" => tool_turn}

      # A restart in between: the blocks come back from the stored part.
      {:ok, state} = ClaudeMessages.recover(opts(), ClaudeMessages.recoverable(state))

      third = %{
        second
        | messages:
            second.messages ++
              [
                %{role: :assistant, content: "Here is a plan."},
                %{role: :user, content: "Thanks"}
              ]
      }

      assert {:ok, %{text: "Done."}, _state} = ClaudeMessages.respond(state, third)
      assert_received {:provider_called, _, body}

      assert [
               %{"role" => "user"},
               %{"role" => "assistant", "content" => ^tool_turn},
               %{"role" => "user"},
               %{"role" => "assistant", "content" => ^text_turn},
               %{"role" => "user", "content" => [%{"type" => "text", "text" => "Thanks"}]}
             ] = body["messages"]
    end

    test "settles cache read and cache write tokens at their prices" do
      stub_response(
        text_response("ok", %{
          "input_tokens" => 100,
          "cache_creation_input_tokens" => 1_000,
          "cache_read_input_tokens" => 2_000,
          "output_tokens" => 50
        })
      )

      {:ok, state} = ClaudeMessages.init(opts())
      assert {:ok, %{usage: usage}, state} = ClaudeMessages.respond(state, @request)

      # The neutral usage counts the whole prompt, cached or not.
      assert usage == %{input_tokens: 3_100, output_tokens: 50}

      # 100 at 1 + 1_000 at 1.25 + 2_000 at 0.1 + 50 at 4 USD/Mtok
      # = 100 + 1_250 + 200 + 200 micro-USD.
      assert %{spent_micros: 1_750, spent_tokens: 3_150, reserved_micros: 0} =
               ClaudeMessages.spend(state)
    end

    test "a realistic response settles exactly from its usage, never from the reservation" do
      # Shaped like a real Claude Opus 5.5 answer (issue #144): cache fields,
      # their per-TTL breakdown and one `message` iteration.
      counts = %{
        "input_tokens" => 2_134,
        "cache_creation_input_tokens" => 9_872,
        "cache_read_input_tokens" => 31_408,
        "output_tokens" => 412
      }

      stub_response(
        message(
          [
            @thinking,
            %{
              "type" => "tool_use",
              "id" => "toolu_01A",
              "name" => "search_recipes",
              "input" => %{}
            }
          ],
          "tool_use",
          Map.merge(counts, %{
            "cache_creation" => %{
              "ephemeral_5m_input_tokens" => 9_872,
              "ephemeral_1h_input_tokens" => 0
            },
            "server_tool_use" => nil,
            "service_tier" => "standard",
            "iterations" => [Map.put(counts, "type", "message")]
          })
        )
        |> Map.put("stop_sequence", nil)
      )

      # The 2026-10-19 battery prices: cache write unset (1.25x input).
      {:ok, state} =
        ClaudeMessages.init(
          opts(
            input_price_micros_per_mtok: 4_000_000,
            output_price_micros_per_mtok: 20_000_000,
            cache_write_price_micros_per_mtok: nil,
            cache_read_price_micros_per_mtok: 200_000,
            fallback_input_price_micros_per_mtok: 5_000_000,
            fallback_output_price_micros_per_mtok: 25_000_000,
            max_tokens: 16_000
          )
        )

      test = self()
      checkpoint = fn model_state -> send(test, {:checkpoint, model_state}) end

      assert {:ok, %{tool_calls: [_], usage: usage}, state} =
               ClaudeMessages.respond(state, Map.put(@request, :checkpoint, checkpoint))

      assert usage == %{input_tokens: 43_414, output_tokens: 412}
      assert_received {:checkpoint, reserved}
      assert ClaudeMessages.spend(reserved).reserved_micros > 720_000

      # 2_134 at 4 + 9_872 at 5 + 31_408 at 0.2 (rounded up) + 412 at 20
      # USD/MTok = 8_536 + 49_360 + 6_282 + 8_240 micro-USD.
      assert %{spent_micros: 72_418, spent_tokens: 43_826, reserved_micros: 0} =
               ClaudeMessages.spend(state)
    end

    test "a fallback-served turn settles every attempt, the fallback model at its own prices" do
      stub_response(
        message(
          [
            %{
              "type" => "fallback",
              "from" => %{"model" => "claude-opus-5-5"},
              "to" => %{"model" => "claude-fallback-fictitious"}
            },
            %{"type" => "text", "text" => "Served by the fallback."}
          ],
          "end_turn",
          %{
            "input_tokens" => 400,
            "output_tokens" => 100,
            "iterations" => [
              %{
                "type" => "message",
                "model" => "claude-opus-5-5",
                "input_tokens" => 500,
                "output_tokens" => 0,
                "cache_read_input_tokens" => 0,
                "cache_creation_input_tokens" => 0
              },
              %{
                "type" => "fallback_message",
                "model" => "claude-fallback-fictitious",
                "input_tokens" => 400,
                "output_tokens" => 100,
                "cache_read_input_tokens" => 0,
                "cache_creation_input_tokens" => 0
              }
            ]
          }
        )
        |> Map.put("model", "claude-fallback-fictitious")
      )

      {:ok, state} = ClaudeMessages.init(opts())

      assert {:ok, %{text: "Served by the fallback.", usage: usage}, state} =
               ClaudeMessages.respond(state, @request)

      assert usage == %{input_tokens: 900, output_tokens: 100}

      # Declined attempt: 500 at 1 USD/Mtok = 500. Fallback: 400 at 2 + 100
      # at 8 USD/Mtok = 1_600. Total 2_100 micro-USD.
      assert %{spent_micros: 2_100, spent_tokens: 1_000} = ClaudeMessages.spend(state)
    end

    test "a dated variant of the configured model is priced as the requested model" do
      stub_response(
        text_response("ok", %{"input_tokens" => 100, "output_tokens" => 10})
        |> Map.put("model", "claude-opus-5-5-20260901")
      )

      {:ok, state} = ClaudeMessages.init(opts())
      assert {:ok, _, state} = ClaudeMessages.respond(state, @request)

      # 100 at 1 + 10 at 4 USD/Mtok = 140 micro-USD (fallback prices: 280).
      assert %{spent_micros: 140, spent_tokens: 110} = ClaudeMessages.spend(state)
    end

    test "without usage.iterations the top-level usage settles at the requested model's prices" do
      # Whatever model string the response names, no fallback_message
      # iteration means no fallback ran.
      stub_response(
        text_response("ok", %{"input_tokens" => 100, "output_tokens" => 10})
        |> Map.put("model", "claude-fallback-fictitious")
      )

      {:ok, state} = ClaudeMessages.init(opts())
      assert {:ok, %{usage: usage}, state} = ClaudeMessages.respond(state, @request)

      assert usage == %{input_tokens: 100, output_tokens: 10}
      assert %{spent_micros: 140, spent_tokens: 110} = ClaudeMessages.spend(state)
    end

    test "an iteration without a model string is priced by its type" do
      stub_response(
        text_response("ok", %{
          "input_tokens" => 100,
          "output_tokens" => 10,
          "iterations" => [%{"type" => "message", "input_tokens" => 100, "output_tokens" => 10}]
        })
      )

      {:ok, state} = ClaudeMessages.init(opts())
      assert {:ok, _, state} = ClaudeMessages.respond(state, @request)

      assert %{spent_micros: 140, spent_tokens: 110} = ClaudeMessages.spend(state)
    end

    test "a refusal followed by a fallback_message iteration prices each at its own rate" do
      # The served-by signal is the iteration type: the declined attempt names
      # a dated variant and the fallback names no model at all.
      stub_response(
        text_response("Served by the fallback.", %{
          "input_tokens" => 400,
          "output_tokens" => 100,
          "iterations" => [
            %{
              "type" => "message",
              "model" => "claude-opus-5-5-20260901",
              "input_tokens" => 500,
              "output_tokens" => 20
            },
            %{"type" => "fallback_message", "input_tokens" => 400, "output_tokens" => 100}
          ]
        })
        |> Map.put("model", "claude-opus-5-5")
      )

      {:ok, state} = ClaudeMessages.init(opts())
      assert {:ok, %{usage: usage}, state} = ClaudeMessages.respond(state, @request)

      assert usage == %{input_tokens: 900, output_tokens: 120}

      # Declined: 500 at 1 + 20 at 4 = 580. Fallback: 400 at 2 + 100 at 8 =
      # 1_600. Total 2_180 micro-USD.
      assert %{spent_micros: 2_180, spent_tokens: 1_020} = ClaudeMessages.spend(state)
    end

    test "a fallback_message iteration while fallbacks are off keeps the worst case as spent" do
      stub_response(
        text_response("ok", %{
          "input_tokens" => 1,
          "output_tokens" => 1,
          "iterations" => [
            %{"type" => "fallback_message", "input_tokens" => 1, "output_tokens" => 1}
          ]
        })
      )

      {:ok, state} =
        ClaudeMessages.init(
          opts(
            fallbacks: false,
            fallback_input_price_micros_per_mtok: nil,
            fallback_output_price_micros_per_mtok: nil
          )
        )

      assert {:ok, %{usage: nil}, state} = ClaudeMessages.respond(state, @request)
      assert %{reserved_micros: 0, spent_micros: spent} = ClaudeMessages.spend(state)
      assert spent >= 4_000
    end

    test "a refusal is a typed error, settled to its usage and never kept in the history" do
      stub_responses([
        message([], "refusal", %{"input_tokens" => 100, "output_tokens" => 0})
        |> Map.put("stop_details", %{"type" => "refusal", "category" => nil}),
        text_response("ok")
      ])

      {:ok, state} = ClaudeMessages.init(opts())

      assert {:error, :provider_refused, state} = ClaudeMessages.respond(state, @request)
      assert %{spent_micros: 100, reserved_micros: 0} = ClaudeMessages.spend(state)
      assert ClaudeMessages.recoverable(state).assistant_turns == %{}
    end

    test "a refusal is not retried through the call bounds: billed once" do
      stub_response(message([], "refusal", %{"input_tokens" => 100, "output_tokens" => 0}))
      {:ok, state} = ClaudeMessages.init(opts())
      bounds = CallBounds.new(policies: %{model: %{timeout_ms: 1_000, backoff_ms: 1}})

      assert {:error, :provider_refused, _state} =
               CallBounds.run(bounds, :model, state, fn model_state, _call ->
                 ClaudeMessages.respond(model_state, @request)
               end)

      assert_received {:provider_called, _, _}
      refute_received {:provider_called, _, _}
    end

    test "a max_tokens stop is a typed error, and its tool calls are never run" do
      stub_response(
        message(
          [
            %{"type" => "text", "text" => "Let me"},
            %{
              "type" => "tool_use",
              "id" => "toolu_cut",
              "name" => "run_optimizer",
              "input" => %{}
            }
          ],
          "max_tokens",
          %{"input_tokens" => 100, "output_tokens" => 1_000}
        )
      )

      {:ok, state} = ClaudeMessages.init(opts())

      assert {:error, :provider_output_truncated, _state} =
               ClaudeMessages.respond(state, @request)
    end

    test "a full context window is a typed error" do
      stub_response(
        message([], "model_context_window_exceeded", %{"input_tokens" => 1, "output_tokens" => 0})
      )

      {:ok, state} = ClaudeMessages.init(opts())

      assert {:error, :provider_context_exceeded, _state} =
               ClaudeMessages.respond(state, @request)
    end

    test "an unexpected stop reason or a turn without text or tool calls is invalid" do
      for body <- [
            message([%{"type" => "text", "text" => "x"}], "pause_turn", %{
              "input_tokens" => 1,
              "output_tokens" => 1
            }),
            message([@thinking], "end_turn", %{"input_tokens" => 1, "output_tokens" => 1}),
            %{"content" => "not a list", "stop_reason" => "end_turn"}
          ] do
        stub_response(body)
        {:ok, state} = ClaudeMessages.init(opts())

        assert {:error, :invalid_provider_response, _state} =
                 ClaudeMessages.respond(state, @request)
      end
    end
  end

  describe "respond/2 spend and failures" do
    test "reserves the worst case of the call and one fallback attempt, refusing over the cap" do
      stub_response(text_response("never"))

      # Worst case output alone: 1_000 tokens at 4 USD/Mtok (requested model)
      # + 1_000 at 8 USD/Mtok (fallback) = 12_000 micro-USD.
      {:ok, state} = ClaudeMessages.init(opts(spend_cap_micros: 11_999))

      assert {:error, :spend_cap_reached, state} = ClaudeMessages.respond(state, @request)
      refute_received {:provider_called, _, _}
      assert ClaudeMessages.spend(state).spent_micros == 0

      {:ok, state} = ClaudeMessages.init(opts(spend_cap_micros: 11_999, fallbacks: false))
      assert {:ok, _, _} = ClaudeMessages.respond(state, @request)
    end

    test "the worst case counts every request byte at the highest input-side price" do
      test = self()

      Req.Test.stub(@stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test, {:request_bytes, byte_size(raw)})
        Req.Test.json(conn, text_response("ok"))
      end)

      # Cache reads priced above input and cache writes (10 USD/Mtok).
      {:ok, state} =
        ClaudeMessages.init(opts(fallbacks: false, cache_read_price_micros_per_mtok: 10_000_000))

      checkpoint = fn model_state -> send(test, {:checkpoint, model_state}) end

      assert {:ok, _, _} =
               ClaudeMessages.respond(state, Map.put(@request, :checkpoint, checkpoint))

      assert_received {:checkpoint, reserved}
      assert_received {:request_bytes, bytes}
      # Every byte at 10 USD/Mtok plus 1_000 output tokens at 4 USD/Mtok.
      assert ClaudeMessages.spend(reserved).reserved_micros == bytes * 10 + 4_000
    end

    test "the cumulative token cap stops further calls" do
      stub_response(text_response("ok", %{"input_tokens" => 900, "output_tokens" => 600}))
      # Worst case per call: every request byte as a token plus 1_000 output
      # tokens; after 1_500 spent tokens the next worst case no longer fits.
      {:ok, state} = ClaudeMessages.init(opts(token_cap: 3_000, fallbacks: false))

      assert {:ok, _, state} = ClaudeMessages.respond(state, @request)
      assert_received {:provider_called, _, _}

      assert {:error, :token_cap_reached, _state} = ClaudeMessages.respond(state, @request)
      refute_received {:provider_called, _, _}
    end

    test "a provider failure is reported and keeps the worst case as spent" do
      Req.Test.stub(@stub, fn conn -> Plug.Conn.send_resp(conn, 529, "overloaded") end)
      {:ok, state} = ClaudeMessages.init(opts())

      assert {:error, :provider_unavailable, state} = ClaudeMessages.respond(state, @request)
      assert %{reserved_micros: 0, spent_micros: spent} = ClaudeMessages.spend(state)
      assert spent >= 12_000
    end

    for {status, reason} <- [
          {401, :provider_unauthorized},
          {403, :provider_unauthorized},
          {400, :provider_rejected_request},
          {404, :provider_rejected_request},
          {413, :provider_rejected_request},
          {409, :provider_conflict},
          {429, :provider_unavailable},
          {500, :provider_unavailable},
          {529, :provider_unavailable}
        ] do
      test "an HTTP #{status} is classified as #{reason}" do
        status = unquote(status)
        Req.Test.stub(@stub, fn conn -> Plug.Conn.send_resp(conn, status, "{}") end)
        {:ok, state} = ClaudeMessages.init(opts())

        assert {:error, unquote(reason), _state} = ClaudeMessages.respond(state, @request)
      end
    end

    test "a transport timeout is classified as a provider timeout" do
      Req.Test.stub(@stub, &Req.Test.transport_error(&1, :timeout))
      {:ok, state} = ClaudeMessages.init(opts())

      assert {:error, :provider_timeout, _state} = ClaudeMessages.respond(state, @request)
    end

    test "the default HTTP deadline ends before the default model attempt deadline" do
      {:ok, state} = ClaudeMessages.init(opts())

      assert state.config.receive_timeout_ms < CallBounds.policies().model.timeout_ms
    end

    test "a slow provider fails as a provider timeout within the attempt deadline, not a kill" do
      # A real HTTP server (a Req.Test plug runs in-process and ignores the
      # receive timeout) that answers after the attempt deadline.
      server =
        start_supervised!(
          {Bandit, plug: {SlowProvider, test: self(), delay_ms: 2_500}, port: 0, ip: :loopback}
        )

      {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

      {:ok, state} =
        ClaudeMessages.init(opts(base_url: "http://127.0.0.1:#{port}/v1", req_options: []))

      bounds = CallBounds.new(policies: %{model: %{timeout_ms: 1_000, retries: 1, backoff_ms: 0}})

      assert {:error, :provider_timeout, state} =
               CallBounds.run(bounds, :model, state, fn model_state, call ->
                 # As the planning loop does, reserved states reach the bounds.
                 request =
                   Map.merge(@request, %{timeout_ms: call.timeout_ms, checkpoint: call.report})

                 ClaudeMessages.respond(model_state, request)
               end)

      # One POST per attempt (the timeout is transient: one retry).
      assert_receive {:slow_provider_called, _}, 1_000
      assert_receive {:slow_provider_called, _}, 1_000
      refute_receive {:slow_provider_called, _}, 100

      # Both attempts settled: nothing left reserved, each worst case spent.
      assert %{reserved_micros: 0, spent_micros: spent} = ClaudeMessages.spend(state)
      assert spent >= 2 * 12_000
    end

    test "the planning loop hands the attempt deadline to the adapter, so a slow call settles" do
      # Default receive timeout (55 s) and a lowered model attempt deadline:
      # only the deadline the loop delivers can end the HTTP call first.
      server =
        start_supervised!(
          {Bandit, plug: {SlowProvider, test: self(), delay_ms: 2_500}, port: 0, ip: :loopback}
        )

      {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

      {:ok, state} =
        ClaudeMessages.init(opts(base_url: "http://127.0.0.1:#{port}/v1", req_options: []))

      bounds = CallBounds.new(policies: %{model: %{timeout_ms: 1_000, retries: 0, backoff_ms: 0}})

      result =
        Loop.run(%{
          model: ClaudeMessages,
          model_state: state,
          instructions: @request.instructions,
          messages: [%{role: :user, content: "Plan something light"}],
          tool_context: %{workspace: %{}},
          allowance: Allowance.new(5),
          emit: fn _event -> :ok end,
          bounds: bounds
        })

      assert result.outcome == {:failed, :provider_timeout}
      assert_receive {:slow_provider_called, _}, 1_000

      # Settled by the adapter, not killed mid-POST with its reservation open.
      assert %{reserved_micros: 0, spent_micros: spent} = ClaudeMessages.spend(result.model_state)
      assert spent > 0
    end

    test "a slow provider cut by the global deadline ends the turn on time, not as a failure" do
      # The global deadline (2 s) is shorter than the default model attempt
      # deadline (60 s), so it bounds the attempt; the adapter ends its HTTP
      # call just before it, leaving too little time for another paid call.
      server =
        start_supervised!(
          {Bandit, plug: {SlowProvider, test: self(), delay_ms: 3_000}, port: 0, ip: :loopback}
        )

      {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

      {:ok, state} =
        ClaudeMessages.init(opts(base_url: "http://127.0.0.1:#{port}/v1", req_options: []))

      bounds =
        CallBounds.new(
          policies: %{model: %{backoff_ms: 1}},
          deadline_at: System.monotonic_time(:millisecond) + 2_000
        )

      result =
        Loop.run(%{
          model: ClaudeMessages,
          model_state: state,
          instructions: @request.instructions,
          messages: [%{role: :user, content: "Plan something light"}],
          tool_context: %{workspace: %{}},
          allowance: Allowance.new(5),
          emit: fn _event -> :ok end,
          bounds: bounds
        })

      assert result.outcome == {:limit_reached, "time"}

      # One paid call reserved and settled; no extra attempt was started.
      assert_receive {:slow_provider_called, _}, 1_000
      refute_receive {:slow_provider_called, _}, 500
      assert %{reserved_micros: 0, spent_micros: spent} = ClaudeMessages.spend(result.model_state)
      assert spent >= 12_000
    end

    test "a 200 response without usage keeps the reservation as spent" do
      stub_response(Map.delete(text_response("hi"), "usage"))
      {:ok, state} = ClaudeMessages.init(opts())

      assert {:ok, %{text: "hi", usage: nil}, state} = ClaudeMessages.respond(state, @request)
      assert %{reserved_micros: 0, spent_micros: spent} = ClaudeMessages.spend(state)
      assert spent >= 12_000
    end

    test "a 200 response with invalid token counts keeps the reservation as spent" do
      for usage <- [
            %{"input_tokens" => "100", "output_tokens" => 50},
            %{"input_tokens" => 1, "output_tokens" => 1, "cache_read_input_tokens" => -1},
            %{"input_tokens" => 1, "output_tokens" => 1, "iterations" => [%{"type" => "message"}]}
          ] do
        stub_response(text_response("hi", usage))
        {:ok, state} = ClaudeMessages.init(opts())

        assert {:ok, %{text: "hi", usage: nil}, state} = ClaudeMessages.respond(state, @request)
        assert %{reserved_micros: 0, spent_micros: spent} = ClaudeMessages.spend(state)
        assert spent >= 12_000
      end
    end

    test "a call over the global concurrency cap is refused before reserving or calling" do
      limiter = start_limiter!()
      holder = hold_provider_slot!(limiter)
      stub_response(text_response("never"))

      {:ok, state} =
        ClaudeMessages.init(opts(max_concurrent_calls: 1, concurrency_limiter: limiter))

      assert {:error, :provider_busy, state} = ClaudeMessages.respond(state, @request)
      refute_received {:provider_called, _, _}
      assert %{spent_micros: 0, reserved_micros: 0} = ClaudeMessages.spend(state)

      Process.exit(holder, :kill)
      wait_until_free(limiter)

      stub_response(text_response("ok"))
      assert {:ok, %{text: "ok"}, _state} = ClaudeMessages.respond(state, @request)
      assert ConcurrencyLimiter.in_use(limiter, :provider_calls) == 0
    end

    test "reports the reserved state through the request checkpoint before calling" do
      test = self()

      Req.Test.stub(@stub, fn conn ->
        send(test, :provider_called)
        Req.Test.json(conn, text_response("ok"))
      end)

      {:ok, state} = ClaudeMessages.init(opts())
      checkpoint = fn model_state -> send(test, {:checkpoint, model_state}) end

      assert {:ok, _, _} =
               ClaudeMessages.respond(state, Map.put(@request, :checkpoint, checkpoint))

      assert_received {:checkpoint, reserved}
      assert ClaudeMessages.spend(reserved).reserved_micros >= 12_000
      assert_received :provider_called
    end
  end
end
