# Throwaway prototype for issue #88 (bounded planning loop). Not production code.
defmodule MealPlannerApi.PrototypePlanningLoop.OpenAIModel do
  @moduledoc """
  Live model: OpenAI Responses API (`POST /v1/responses`) with function tools.

  The conversation is replayed in full on every call: prior output items
  (including reasoning items) are appended to `input` verbatim, followed by
  `function_call_output` items. Responses stay stored on the OpenAI side
  (API default) so replayed reasoning items resolve by id.

  The API key is read from `OPENAI_API_KEY` at call time and is never kept in
  state, printed or logged. Every call is gated by the spend ledger, which
  holds a worst-case reservation for the call until its real cost is known.
  """

  @behaviour MealPlannerApi.PrototypePlanningLoop.Model

  alias MealPlannerApi.PrototypePlanningLoop.SpendLedger

  @url "https://api.openai.com/v1/responses"
  @default_model "gpt-6.1-sol"
  @max_output_tokens 8_000
  @receive_timeout_ms 45_000

  def model_name, do: System.get_env("PROTOTYPE_OPENAI_MODEL") || @default_model

  def key_present?, do: System.get_env("OPENAI_API_KEY") not in [nil, ""]

  @impl true
  def respond(state, request) do
    body = %{
      model: model_name(),
      instructions: request.instructions,
      input: request.input,
      tools: request.tools,
      max_output_tokens: @max_output_tokens
    }

    # Rough upper estimate of input tokens: three bytes per token.
    estimated_input_tokens = div(byte_size(Jason.encode!(body)), 3)
    worst_case = SpendLedger.worst_case_usd(estimated_input_tokens, @max_output_tokens)

    with true <- key_present?() || {:error, "OPENAI_API_KEY is not set"},
         :ok <- SpendLedger.reserve(worst_case) do
      call(state, body, worst_case)
    end
  end

  # From here on the worst case is already in the ledger as spent. It is
  # replaced by the real cost only on a complete response, and dropped only
  # when the provider rejected the request outright (4xx). Any other exit,
  # including this process being killed by the loop's timeout, leaves it there.
  defp call(state, body, reserved) do
    result =
      Req.post(@url,
        json: body,
        auth: {:bearer, System.get_env("OPENAI_API_KEY")},
        # Shorter than the loop's 60 s kill, so a slow call normally ends here
        # with an error instead of a brutal kill.
        receive_timeout: @receive_timeout_ms,
        retry: false
      )

    case result do
      {:ok,
       %Req.Response{status: 200, body: %{"output" => output, "usage" => %{} = usage} = response}} ->
        usage = usage(usage)
        spend = SpendLedger.settle(reserved, usage)
        {:ok, %{output: output, usage: usage, spend: spend, status: response["status"]}, state}

      {:ok, %Req.Response{status: 200}} ->
        {:error,
         "OpenAI returned 200 without output or usage; the reservation of USD #{SpendLedger.fmt(reserved)} stays counted as spent"}

      # The body of an authentication failure can echo part of the key.
      {:ok, %Req.Response{status: 401}} ->
        SpendLedger.release(reserved)
        {:error, "OpenAI returned 401: the key in OPENAI_API_KEY was rejected"}

      {:ok, %Req.Response{status: status, body: body}} when status in 400..499 ->
        SpendLedger.release(reserved)
        {:error, "OpenAI returned HTTP #{status}: #{error_message(body)}"}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error,
         "OpenAI returned HTTP #{status}: #{error_message(body)}; the reservation of USD #{SpendLedger.fmt(reserved)} stays counted as spent"}

      {:error, exception} ->
        {:error,
         "request to OpenAI failed: #{Exception.message(exception)}; the reservation of USD #{SpendLedger.fmt(reserved)} stays counted as spent"}
    end
  end

  # `cached_tokens` is a subset of `input_tokens`.
  defp usage(usage) do
    %{
      input_tokens: usage["input_tokens"] || 0,
      cached_input_tokens: get_in(usage, ["input_tokens_details", "cached_tokens"]) || 0,
      output_tokens: usage["output_tokens"] || 0
    }
  end

  defp error_message(%{"error" => %{"message" => message}}) when is_binary(message), do: message
  defp error_message(_body), do: "no error message in the response body"
end
