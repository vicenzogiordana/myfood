defmodule MealPlannerApi.PlanningAgent.Model.OpenAIResponses do
  @moduledoc """
  OpenAI Responses API adapter for the planning agent (spec #93): one
  provider and one model (`gpt-6.1-sol`), no failover. Provider down means
  "cannot plan now".

  Paid execution is impossible unless it is bounded: `init/1` refuses with
  `:spend_caps_unconfigured` when the spend cap or the token cap is unset,
  and with `:pricing_unconfigured` when token prices are unknown. Before each
  call the worst-case cost is reserved in a `MealPlannerApi.PlanningAgent.SpendLedger`
  (every request byte counted as one input token, plus `max_output_tokens`)
  and the call is refused when a cap would be exceeded; afterwards the
  reservation is settled to the reported usage, or kept as spent when the
  usage is missing or invalid. The reserved state is reported through the
  request's optional `:checkpoint` callback before the call is made.

  The numeric caps are a human decision and are not set by default. Caps
  apply per Planning Session: every attempt of every model call, retries
  included, draws on the same ledger.

  Provider failures are typed: `:provider_unauthorized` (401/403),
  `:provider_rejected_request` (other 4xx), `:provider_conflict` (409),
  `:provider_timeout` (transport timeout) and `:provider_unavailable`
  (408, 429, 5xx, other transport errors). Only the last two are transient.

  ## Configuration

      config :meal_planner_api, MealPlannerApi.PlanningAgent.Model.OpenAIResponses,
        api_key: "...",
        model: "gpt-6.1-sol",
        base_url: "https://api.openai.com/v1",
        spend_cap_micros: nil,                 # micro-USD per execution
        token_cap: nil,                        # cumulative tokens per execution
        input_price_micros_per_mtok: nil,      # micro-USD per million input tokens
        output_price_micros_per_mtok: nil,     # micro-USD per million output tokens
        max_output_tokens: 4_096,
        receive_timeout_ms: 60_000

  Options passed to `init/1` override the application config.
  """

  @behaviour MealPlannerApi.PlanningAgent.Model

  alias MealPlannerApi.PlanningAgent.SpendLedger

  @defaults [
    model: "gpt-6.1-sol",
    base_url: "https://api.openai.com/v1",
    max_output_tokens: 4_096,
    receive_timeout_ms: 60_000,
    req_options: []
  ]

  @impl true
  def init(opts) do
    config =
      @defaults
      |> Keyword.merge(Application.get_env(:meal_planner_api, __MODULE__, []))
      |> Keyword.merge(opts)
      |> Map.new()

    with {:ok, ledger} <- SpendLedger.new(config[:spend_cap_micros], config[:token_cap]),
         :ok <- validate_pricing(config),
         :ok <- validate_api_key(config) do
      {:ok, %{config: config, ledger: ledger}}
    end
  end

  @doc "Spend summary of the execution so far."
  @spec spend(map()) :: map()
  def spend(%{ledger: ledger}), do: SpendLedger.summary(ledger)

  @impl true
  def respond(state, request) do
    body = body(state.config, request)
    reservation = worst_case(state.config, body)

    case SpendLedger.reserve(state.ledger, reservation) do
      {:ok, ledger} ->
        state = %{state | ledger: ledger}
        # The owner keeps the reserved state, so a turn killed mid-call still
        # counts the reservation.
        checkpoint(request, state)

        case post(state.config, body) do
          {:ok, response} ->
            {usage, actual} =
              case usage(response) do
                {:ok, usage} -> {usage, cost(state.config, usage)}
                # Usage is unknown: reported as unknown (never as zero) and
                # the worst case stays spent.
                :unknown -> {nil, reservation}
              end

            state = %{state | ledger: SpendLedger.settle(state.ledger, reservation, actual)}

            case parse(response) do
              {:ok, text, tool_calls} ->
                {:ok, %{text: text, tool_calls: tool_calls, usage: usage}, state}

              :error ->
                {:error, :invalid_provider_response, state}
            end

          {:error, reason} ->
            # Usage is unknown: the worst case stays spent.
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

  defp body(config, request) do
    %{
      "model" => config.model,
      "instructions" => request.instructions,
      "input" => Enum.map(request.messages, &input_item/1),
      "tools" =>
        Enum.map(request.tools, fn tool ->
          %{
            "type" => "function",
            "name" => tool.name,
            "description" => tool.description,
            "parameters" => tool.parameters
          }
        end),
      "max_output_tokens" => config.max_output_tokens,
      "store" => false
    }
  end

  defp input_item(%{role: :user, content: content}), do: %{"role" => "user", "content" => content}

  defp input_item(%{role: :assistant, content: content}),
    do: %{"role" => "assistant", "content" => content}

  defp input_item(%{role: :tool_call, id: id, name: name, arguments: arguments}),
    do: %{
      "type" => "function_call",
      "call_id" => id,
      "name" => name,
      "arguments" => Jason.encode!(arguments)
    }

  # Tool output travels only as a function_call_output item: data, never
  # instructions.
  defp input_item(%{role: :tool_result, id: id, content: content}),
    do: %{"type" => "function_call_output", "call_id" => id, "output" => Jason.encode!(content)}

  defp post(config, body) do
    [
      url: config.base_url <> "/responses",
      json: body,
      auth: {:bearer, config.api_key},
      receive_timeout: config.receive_timeout_ms,
      retry: false
    ]
    |> Keyword.merge(config.req_options)
    |> Req.post()
    |> case do
      {:ok, %Req.Response{status: 200, body: %{} = response}} ->
        {:ok, response}

      {:ok, %Req.Response{status: status}} ->
        {:error, status_reason(status)}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, :provider_timeout}

      {:error, _exception} ->
        {:error, :provider_unavailable}
    end
  end

  # Only `:provider_unavailable` and `:provider_timeout` are transient (see
  # `MealPlannerApi.PlanningAgent.CallBounds`). Permission, invalid request
  # and conflict answers are never retried automatically.
  defp status_reason(status) when status in [401, 403], do: :provider_unauthorized
  defp status_reason(409), do: :provider_conflict
  defp status_reason(status) when status in [408, 429], do: :provider_unavailable
  defp status_reason(status) when status in 400..499, do: :provider_rejected_request
  defp status_reason(_status), do: :provider_unavailable

  # ---------------------------------------------------------------------------
  # Response
  # ---------------------------------------------------------------------------

  # An incomplete response (for example cut off at max_output_tokens) is not a
  # finished assistant turn, even when it carries partial text.
  defp parse(%{"status" => "incomplete"}), do: :error

  defp parse(%{"output" => output}) when is_list(output) do
    text =
      for %{"type" => "message", "content" => content} <- output,
          %{"type" => "output_text", "text" => text} <- content,
          do: text

    calls =
      for %{"type" => "function_call", "call_id" => id, "name" => name} = call <- output do
        %{id: id, name: name, arguments: decode_arguments(call["arguments"])}
      end

    case {text, calls} do
      # Neither a message nor a tool call (for example only a reasoning item):
      # nothing to show the Member and nothing to run.
      {[], []} -> :error
      {[], calls} -> {:ok, nil, calls}
      {text, calls} -> {:ok, Enum.join(text), calls}
    end
  end

  defp parse(_response), do: :error

  defp decode_arguments(raw) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, %{} = arguments} -> arguments
      _ -> %{}
    end
  end

  defp decode_arguments(_raw), do: %{}

  defp usage(%{"usage" => %{"input_tokens" => input, "output_tokens" => output}})
       when is_integer(input) and input >= 0 and is_integer(output) and output >= 0,
       do: {:ok, %{input_tokens: input, output_tokens: output}}

  defp usage(_response), do: :unknown

  defp checkpoint(%{checkpoint: checkpoint}, state) when is_function(checkpoint, 1),
    do: checkpoint.(state)

  defp checkpoint(_request, _state), do: :ok

  # ---------------------------------------------------------------------------
  # Spend
  # ---------------------------------------------------------------------------

  defp worst_case(config, body) do
    cost(config, %{
      input_tokens: body |> Jason.encode!() |> byte_size(),
      output_tokens: config.max_output_tokens
    })
  end

  defp cost(config, %{input_tokens: input, output_tokens: output}) do
    micros =
      ceil_div(input * config.input_price_micros_per_mtok, 1_000_000) +
        ceil_div(output * config.output_price_micros_per_mtok, 1_000_000)

    %{micros: micros, tokens: input + output}
  end

  defp ceil_div(numerator, denominator), do: div(numerator + denominator - 1, denominator)

  defp validate_pricing(config) do
    if non_neg_integer?(config[:input_price_micros_per_mtok]) and
         non_neg_integer?(config[:output_price_micros_per_mtok]) and
         is_integer(config[:max_output_tokens]) and config[:max_output_tokens] > 0,
       do: :ok,
       else: {:error, :pricing_unconfigured}
  end

  defp validate_api_key(config) do
    case config[:api_key] do
      key when is_binary(key) and key != "" -> :ok
      _ -> {:error, :provider_unconfigured}
    end
  end

  defp non_neg_integer?(value), do: is_integer(value) and value >= 0
end
