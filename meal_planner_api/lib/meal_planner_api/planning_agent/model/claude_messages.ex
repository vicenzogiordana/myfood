defmodule MealPlannerApi.PlanningAgent.Model.ClaudeMessages do
  @moduledoc """
  Anthropic Messages API adapter for the planning agent (issue #141, spec
  #93), over raw HTTP with `Req` (`POST /v1/messages`). Default model
  `claude-haiku-5-5` (issue #156: it passes the quality battery at a
  fraction of the cost of `claude-opus-5-5`).

  ## Request

  Every request sends adaptive thinking with an explicit `output_config.effort` (default
  `medium`). It never sends `budget_tokens`, sampling parameters, an
  assistant prefill or a forced `tool_choice`: tool use is `auto`. Neutral
  tools become Claude tool definitions; tool calls and results travel as
  `tool_use` / `tool_result` blocks, every result of a turn in one user
  message. Tool output is data, carried only as a tool result.

  Prompt caching: the instructions end in a cache breakpoint (caching the
  tools and the instructions, which render first), and top-level automatic
  caching covers the growing conversation.

  ## Preserved thinking

  The adapter keeps the exact assistant content blocks it received
  (thinking, text, tool_use, fallback markers) and resends them unchanged on
  later requests of the same Planning Session, so the history is
  append-only. The neutral message shape is not extended: the blocks live in
  the adapter state under `assistant_turns`, keyed by the position of the
  neutral messages they produced and by their identity (tool call ids, or
  the text), and are part of `recoverable/1`. Without a matching entry (an
  older session) the blocks are rebuilt from the neutral messages. The
  instructions and tools must stay byte-identical for replayed thinking to
  stay valid.

  `assistant_turns` is never pruned within a Planning Session; it is bounded
  by the Session's own limits. Its persisted copy (the
  `planning_agent_recoveries` row) is deleted whenever the Session ends:
  confirmed, cancelled, expired or lock lost (`PlanningRepo` and the
  Planning Session sweeper).

  ## Stop reasons

  `refusal` becomes `:provider_refused`, `max_tokens`
  `:provider_output_truncated` (its tool calls are never run) and
  `model_context_window_exceeded` `:provider_context_exceeded`; any other
  stop that is not a finished turn (`end_turn`, `tool_use`,
  `stop_sequence`) is `:invalid_provider_response`. None is transient.

  Server-side refusal fallback (`fallbacks: "default"`, beta
  `server-side-fallback-2026-07-01`) is off by default, because Claude
  Haiku 5.5 rejects the parameter. With `fallbacks: true` (for models that
  accept it, such as `claude-opus-5-5`) a safety-classifier decline is
  re-run on the model Anthropic recommends for its category, in the same
  call.

  ## Spend

  `init/1` refuses without caps (`:spend_caps_unconfigured`), prices
  (`:pricing_unconfigured`) or API key (`:provider_unconfigured`). The
  money cap is the real limit; the token cap is a safety net (issue #154).
  Before each call a reservation is made and reported through the
  request's `:checkpoint`. Money is the worst case: every request byte
  counted as one input token at the highest of the input, cache-write and
  cache-read prices, plus `max_tokens` output, for the requested model and
  for each of `max_fallback_attempts` fallback attempts at the fallback
  prices. Tokens are a realistic estimate: the request bytes divided by
  three, plus `max_tokens` once. Afterwards both are settled from `usage`:
  input, cache write, cache read and output tokens, summed over every
  attempt of `usage.iterations`. Cache reads are paid at their price but
  never count toward the token cap. The
  iteration `type` says which model ran it: a `fallback_message` iteration
  is priced at the fallback prices, any other iteration at the requested
  model's prices. The `model` string of the response or of an iteration is
  never read, so a missing, dated or aliased model name cannot change the
  price. Without `usage.iterations` the top-level `usage` is settled at the
  requested model's prices. Missing or invalid usage, or a
  `fallback_message` iteration while fallbacks are off, keeps the worst case
  spent. A fallback chain longer than `max_fallback_attempts` is still
  settled from its reported usage.

  Fallback prices are mandatory while fallbacks are on: set them to the
  highest price among the possible fallback models. Cache prices default
  to 1.25x (5-minute writes) and 1x (reads, conservative) the input price.

  ## Configuration

      config :meal_planner_api, MealPlannerApi.PlanningAgent.Model.ClaudeMessages,
        api_key: "...",
        model: "claude-haiku-5-5",
        effort: "medium",                            # low | medium | high | xhigh | max
        base_url: "https://api.anthropic.com/v1",
        spend_cap_micros: nil,                       # micro-USD per Planning Session
        token_cap: nil,                              # cumulative tokens per Planning Session
        max_concurrent_calls: nil,                   # provider calls in flight, all sessions
        input_price_micros_per_mtok: nil,
        output_price_micros_per_mtok: nil,
        cache_write_price_micros_per_mtok: nil,      # default 1.25x input
        cache_read_price_micros_per_mtok: nil,       # default 1x input
        fallbacks: false,                            # true needs the fallback prices
        max_fallback_attempts: 1,
        fallback_input_price_micros_per_mtok: nil,
        fallback_output_price_micros_per_mtok: nil,
        max_tokens: 16_000,                          # thinking plus reply
        receive_timeout_ms: 55_000

  Options passed to `init/1` override the application config.

  ## Deadlines

  The HTTP receive timeout must end before the attempt deadline of
  `MealPlannerApi.PlanningAgent.CallBounds` (60 s for `:model` by default),
  so a slow answer fails as a settled `:provider_timeout` instead of the
  attempt being killed with its reservation still open. Its default
  (55 s) stays below the default `:model` deadline; a request may also
  carry `:timeout_ms` (the attempt's effective deadline), and the receive
  timeout is then capped just below it. A slow model whose turns need
  more than 55 s needs a larger `receive_timeout_ms` and a larger `:model`
  call policy (`timeout_ms`) together.
  """

  @behaviour MealPlannerApi.PlanningAgent.Model

  alias MealPlannerApi.PlanningAgent.{ConcurrencyLimiter, SpendLedger}
  alias MealPlannerApi.PlanningAgent.Model.PaidCall

  @api_version "2023-06-01"
  @fallback_beta "server-side-fallback-2026-07-01"
  @efforts ~w(low medium high xhigh max)
  @finished ~w(end_turn tool_use stop_sequence)
  @ephemeral %{"type" => "ephemeral"}
  @bytes_per_token 3

  @defaults [
    model: "claude-haiku-5-5",
    effort: "medium",
    base_url: "https://api.anthropic.com/v1",
    fallbacks: false,
    max_fallback_attempts: 1,
    max_tokens: 16_000,
    receive_timeout_ms: 55_000,
    concurrency_limiter: ConcurrencyLimiter,
    req_options: []
  ]

  @impl true
  def init(opts) do
    config =
      @defaults
      |> Keyword.merge(Application.get_env(:meal_planner_api, __MODULE__, []))
      |> Keyword.merge(opts)
      |> Map.new()
      |> with_cache_prices()

    with {:ok, ledger} <- SpendLedger.new(config[:spend_cap_micros], config[:token_cap]),
         :ok <- PaidCall.validate_concurrency(config),
         :ok <- validate_pricing(config),
         :ok <- PaidCall.validate_api_key(config),
         :ok <- validate_effort(config) do
      {:ok, %{config: config, ledger: ledger, assistant_turns: %{}}}
    end
  end

  @doc """
  The spend ledger (an open reservation counted as spent) and the preserved
  assistant content blocks, kept across a server restart. The
  configuration, with its API key, is never part of it.
  """
  @impl true
  def recoverable(%{ledger: ledger, assistant_turns: turns}),
    do: Map.put(PaidCall.recoverable_spend(ledger), :assistant_turns, turns)

  @doc "A recovered Planning Session's state: fresh configuration, kept spend and blocks."
  @impl true
  def recover(opts, %{spent_micros: _, spent_tokens: _} = saved) do
    with {:ok, state} <- init(opts) do
      {:ok,
       %{
         state
         | ledger: PaidCall.restore_spend(state.ledger, saved),
           assistant_turns: Map.get(saved, :assistant_turns, %{})
       }}
    end
  end

  @doc "Spend summary of the Planning Session so far."
  @spec spend(map()) :: map()
  def spend(%{ledger: ledger}), do: SpendLedger.summary(ledger)

  @impl true
  def respond(state, request),
    do: PaidCall.limited(state.config, state, fn -> paid_call(state, request) end)

  defp paid_call(state, request) do
    body = body(state, request)
    reservation = worst_case(state.config, body)

    case SpendLedger.reserve(state.ledger, reservation) do
      {:ok, ledger} ->
        state = %{state | ledger: ledger}
        PaidCall.checkpoint(request, state)

        case post(state.config, body, receive_timeout(state.config, request)) do
          {:ok, response} ->
            {usage, actual} =
              case usage(state.config, response) do
                {:ok, usage, actual} -> {usage, actual}
                :unknown -> {nil, reservation}
              end

            state = %{state | ledger: SpendLedger.settle(state.ledger, reservation, actual)}

            case parse(response) do
              {:ok, text, tool_calls} ->
                state = keep_turn(state, length(request.messages), response, text, tool_calls)
                {:ok, %{text: text, tool_calls: tool_calls, usage: usage}, state}

              {:error, reason} ->
                {:error, reason, state}
            end

          {:error, reason} ->
            {:error, reason,
             %{state | ledger: SpendLedger.settle(state.ledger, reservation, reservation)}}
        end

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  # ---------------------------------------------------------------------------
  # Request
  # ---------------------------------------------------------------------------

  defp body(state, request) do
    config = state.config

    body = %{
      "model" => config.model,
      "max_tokens" => config.max_tokens,
      "system" => [
        %{"type" => "text", "text" => request.instructions, "cache_control" => @ephemeral}
      ],
      "tools" =>
        Enum.map(request.tools, fn tool ->
          %{
            "name" => tool.name,
            "description" => tool.description,
            "input_schema" => tool.parameters
          }
        end),
      "tool_choice" => %{"type" => "auto"},
      "thinking" => %{"type" => "adaptive"},
      "output_config" => %{"effort" => config.effort},
      "cache_control" => @ephemeral,
      "messages" => messages(request.messages, state.assistant_turns)
    }

    if config.fallbacks, do: Map.put(body, "fallbacks", "default"), else: body
  end

  # Neutral messages become alternating Claude messages: consecutive blocks
  # of the same role share one message (so every tool result of a turn is in
  # one user message).
  defp messages(neutral, turns) do
    neutral
    |> Enum.with_index()
    |> Enum.chunk_while(nil, &chunk/2, &flush/1)
    |> Enum.flat_map(&message(&1, turns))
    |> Enum.chunk_by(& &1["role"])
    |> Enum.map(fn [%{"role" => role} | _] = same ->
      %{"role" => role, "content" => Enum.flat_map(same, & &1["content"])}
    end)
  end

  # Consecutive tool calls belong to one assistant turn.
  defp chunk({%{role: :tool_call} = call, _index}, {:tool_calls, start, calls}),
    do: {:cont, {:tool_calls, start, calls ++ [call]}}

  defp chunk({%{role: :tool_call} = call, index}, acc),
    do: emit(acc, {:tool_calls, index, [call]})

  defp chunk({message, index}, acc), do: emit(acc, {:single, index, message})

  defp emit(nil, next), do: {:cont, next}
  defp emit(acc, next), do: {:cont, acc, next}

  defp flush(nil), do: {:cont, nil}
  defp flush(acc), do: {:cont, acc, nil}

  defp message({:tool_calls, index, calls}, turns) do
    content =
      kept(turns, index, fingerprint(calls)) ||
        Enum.map(calls, fn call ->
          %{"type" => "tool_use", "id" => call.id, "name" => call.name, "input" => call.arguments}
        end)

    [%{"role" => "assistant", "content" => content}]
  end

  defp message({:single, index, %{role: :assistant, content: text}}, turns) do
    case kept(turns, index, {:text, text}) do
      nil when text in [nil, ""] -> []
      nil -> [%{"role" => "assistant", "content" => [%{"type" => "text", "text" => text}]}]
      content -> [%{"role" => "assistant", "content" => content}]
    end
  end

  defp message({:single, _index, %{role: :user, content: text}}, _turns),
    do: [%{"role" => "user", "content" => [%{"type" => "text", "text" => text}]}]

  defp message({:single, _index, %{role: :tool_result, id: id, content: content}}, _turns),
    do: [
      %{
        "role" => "user",
        "content" => [
          %{"type" => "tool_result", "tool_use_id" => id, "content" => Jason.encode!(content)}
        ]
      }
    ]

  defp kept(turns, index, fingerprint) do
    case Map.get(turns, index) do
      %{fingerprint: ^fingerprint, content: content} -> content
      _ -> nil
    end
  end

  defp fingerprint(calls), do: {:tool_calls, Enum.map(calls, & &1.id)}

  # The planning loop appends the tool calls of a tool-calling turn, or the
  # text (nil as "") of a final one, right after the request's messages.
  defp keep_turn(state, index, response, text, tool_calls) do
    fingerprint = if tool_calls == [], do: {:text, text || ""}, else: fingerprint(tool_calls)
    turn = %{fingerprint: fingerprint, content: response["content"]}
    %{state | assistant_turns: Map.put(state.assistant_turns, index, turn)}
  end

  # Capped just below the attempt deadline, when the request carries it, so
  # the HTTP call ends first and its reservation is settled.
  defp receive_timeout(config, %{timeout_ms: timeout_ms})
       when is_integer(timeout_ms) and timeout_ms > 0,
       do: min(config.receive_timeout_ms, max(timeout_ms - min(1_000, div(timeout_ms, 5)), 1))

  defp receive_timeout(config, _request), do: config.receive_timeout_ms

  defp post(config, body, receive_timeout) do
    beta = if config.fallbacks, do: [{"anthropic-beta", @fallback_beta}], else: []

    [
      url: config.base_url <> "/messages",
      json: body,
      headers: [{"x-api-key", config.api_key}, {"anthropic-version", @api_version} | beta],
      receive_timeout: receive_timeout
    ]
    |> Keyword.merge(config.req_options)
    |> PaidCall.post()
  end

  # ---------------------------------------------------------------------------
  # Response
  # ---------------------------------------------------------------------------

  # Branch on stop_reason before reading content: a refusal may carry no
  # content or a cut-off tool call.
  defp parse(%{"stop_reason" => "refusal"}), do: {:error, :provider_refused}
  defp parse(%{"stop_reason" => "max_tokens"}), do: {:error, :provider_output_truncated}

  defp parse(%{"stop_reason" => "model_context_window_exceeded"}),
    do: {:error, :provider_context_exceeded}

  defp parse(%{"stop_reason" => stop, "content" => content})
       when stop in @finished and is_list(content) do
    text = for %{"type" => "text", "text" => text} <- content, is_binary(text), do: text

    calls =
      for %{"type" => "tool_use", "id" => id, "name" => name} = block <- content do
        input = if is_map(block["input"]), do: block["input"], else: %{}
        %{id: id, name: name, arguments: input}
      end

    case {text, calls} do
      # Only thinking: nothing to show the Member and nothing to run.
      {[], []} -> {:error, :invalid_provider_response}
      {[], calls} -> {:ok, nil, calls}
      {text, calls} -> {:ok, Enum.join(text), calls}
    end
  end

  defp parse(_response), do: {:error, :invalid_provider_response}

  # The top-level usage covers only the attempt that produced the message;
  # with a fallback, usage.iterations records every attempt. Which model ran
  # an attempt is read from the iteration type (`fallback_message` is a
  # fallback attempt), never from the `model` string, which may be absent,
  # dated or an alias.
  defp usage(config, %{"usage" => %{"iterations" => [_ | _] = iterations}}) do
    iterations
    |> Enum.map(&attempt(&1, prices(config, &1)))
    |> sum()
  end

  defp usage(config, %{"usage" => %{} = usage}),
    do: sum([attempt(usage, primary_prices(config))])

  defp usage(_config, _response), do: :unknown

  defp attempt(_usage, :unknown), do: :unknown

  defp attempt(usage, prices) do
    # Cache counts are absent when nothing was cached; the others are required.
    counts = [
      usage["input_tokens"],
      Map.get(usage, "cache_creation_input_tokens", 0),
      Map.get(usage, "cache_read_input_tokens", 0),
      usage["output_tokens"]
    ]

    if Enum.all?(counts, &PaidCall.non_neg_integer?/1) do
      [input, write, read, output] = counts

      micros =
        PaidCall.micros(input, prices.input) + PaidCall.micros(write, prices.cache_write) +
          PaidCall.micros(read, prices.cache_read) + PaidCall.micros(output, prices.output)

      # Cache reads are paid (at their price) but never count toward the
      # token cap, a safety net beside the money cap (issue #154).
      {:ok,
       %{
         prompt: input + write + read,
         capped: input + write + output,
         output: output,
         micros: micros
       }}
    else
      :unknown
    end
  end

  defp sum(attempts) do
    if Enum.all?(attempts, &match?({:ok, _}, &1)) do
      attempts = Enum.map(attempts, fn {:ok, attempt} -> attempt end)
      prompt = attempts |> Enum.map(& &1.prompt) |> Enum.sum()
      output = attempts |> Enum.map(& &1.output) |> Enum.sum()
      micros = attempts |> Enum.map(& &1.micros) |> Enum.sum()
      tokens = attempts |> Enum.map(& &1.capped) |> Enum.sum()

      {:ok, %{input_tokens: prompt, output_tokens: output}, %{micros: micros, tokens: tokens}}
    else
      :unknown
    end
  end

  # A fallback attempt the request never enabled has no configured price:
  # its settlement is unknown, so the worst case stays spent.
  defp prices(%{fallbacks: true} = config, %{"type" => "fallback_message"}),
    do: fallback_prices(config)

  defp prices(_config, %{"type" => "fallback_message"}), do: :unknown
  defp prices(config, _iteration), do: primary_prices(config)

  defp primary_prices(config) do
    %{
      input: config.input_price_micros_per_mtok,
      output: config.output_price_micros_per_mtok,
      cache_write: config.cache_write_price_micros_per_mtok,
      cache_read: config.cache_read_price_micros_per_mtok
    }
  end

  defp fallback_prices(config) do
    input = config.fallback_input_price_micros_per_mtok

    %{
      input: input,
      output: config.fallback_output_price_micros_per_mtok,
      cache_write: cache_write_default(input),
      cache_read: input
    }
  end

  # ---------------------------------------------------------------------------
  # Spend
  # ---------------------------------------------------------------------------

  # The money reservation is the conservative worst case. The token
  # reservation is a realistic estimate (issue #154): the token cap is only a
  # safety net, so it reserves the request at three bytes per token plus
  # `max_tokens` once, never doubled for a fallback attempt.
  defp worst_case(config, body) do
    input = body |> Jason.encode!() |> byte_size()
    first = attempt_worst_micros(primary_prices(config), input, config.max_tokens)

    micros =
      if config.fallbacks do
        fallback = attempt_worst_micros(fallback_prices(config), input, config.max_tokens)
        first + config.max_fallback_attempts * fallback
      else
        first
      end

    %{
      micros: micros,
      tokens: div(input + @bytes_per_token - 1, @bytes_per_token) + config.max_tokens
    }
  end

  defp attempt_worst_micros(prices, input, output),
    do:
      PaidCall.micros(input, Enum.max([prices.input, prices.cache_write, prices.cache_read])) +
        PaidCall.micros(output, prices.output)

  defp with_cache_prices(config) do
    input = config[:input_price_micros_per_mtok]

    config
    |> Map.put(
      :cache_write_price_micros_per_mtok,
      config[:cache_write_price_micros_per_mtok] || cache_write_default(input)
    )
    |> Map.put(
      :cache_read_price_micros_per_mtok,
      config[:cache_read_price_micros_per_mtok] || input
    )
  end

  defp cache_write_default(input) when is_integer(input), do: div(input * 5 + 3, 4)
  defp cache_write_default(_input), do: nil

  defp validate_pricing(config) do
    prices =
      [
        :input_price_micros_per_mtok,
        :output_price_micros_per_mtok,
        :cache_write_price_micros_per_mtok,
        :cache_read_price_micros_per_mtok
      ] ++
        if(config.fallbacks,
          do: [:fallback_input_price_micros_per_mtok, :fallback_output_price_micros_per_mtok],
          else: []
        )

    if Enum.all?(prices, &PaidCall.non_neg_integer?(config[&1])) and
         positive_integer?(config[:max_tokens]) and
         (not config.fallbacks or PaidCall.non_neg_integer?(config[:max_fallback_attempts])),
       do: :ok,
       else: {:error, :pricing_unconfigured}
  end

  defp validate_effort(%{effort: effort}) when effort in @efforts, do: :ok
  defp validate_effort(_config), do: {:error, :provider_unconfigured}

  defp positive_integer?(value), do: is_integer(value) and value > 0
end
