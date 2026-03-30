defmodule MealPlannerApi.AI.GeminiClient do
  @moduledoc """
  Gemini AI client used for both streamed chat (fallback via sync call) and sync generation.
  """

  @behaviour MealPlannerApi.AI.Client

  alias MealPlannerApiWeb.Endpoint

  @default_model "gemini-2.5-flash-lite"
  @default_base_url "https://generativelanguage.googleapis.com"

  @impl true
  def stream_chat_completion(topic, prompt, opts) do
    Task.start(fn ->
      request_id = Keyword.get(opts, :request_id) || "req_stream"
      account_id = get_in(opts, [:user, :account_id])

      Endpoint.broadcast(topic, "ai_response_started", %{
        request_id: request_id,
        account_id: account_id
      })

      case generate_text(prompt, opts) do
        {:ok, text} ->
          text
          |> chunk_text(7)
          |> Enum.each(fn chunk ->
            Endpoint.broadcast(topic, "ai_response_chunk", %{
              request_id: request_id,
              account_id: account_id,
              chunk: chunk,
              done: false
            })
          end)

          Endpoint.broadcast(topic, "ai_response_chunk", %{
            request_id: request_id,
            account_id: account_id,
            chunk: "",
            done: true
          })

          Endpoint.broadcast(topic, "ai_response_finished", %{
            request_id: request_id,
            account_id: account_id
          })

        {:error, reason} ->
          Endpoint.broadcast(topic, "ai_response_error", %{
            request_id: request_id,
            account_id: account_id,
            error: inspect(reason)
          })
      end
    end)

    :ok
  end

  @impl true
  def generate_text(prompt, opts) when is_binary(prompt) and is_list(opts) do
    with {:ok, api_key} <- fetch_api_key(),
         {:ok, response_body} <- do_generate(prompt, opts, api_key),
         {:ok, text} <- parse_text(response_body) do
      {:ok, text}
    end
  end

  defp do_generate(prompt, opts, api_key) do
    model = Application.get_env(:meal_planner_api, :gemini_model, @default_model)
    base_url = Application.get_env(:meal_planner_api, :gemini_base_url, @default_base_url)
    timeout = Application.get_env(:meal_planner_api, :gemini_timeout_ms, 15_000)

    url =
      base_url <> "/v1beta/models/" <> model <> ":generateContent?key=" <> URI.encode(api_key)

    system_prompt =
      case Keyword.get(opts, :system_prompt) do
        value when is_binary(value) and value != "" -> value
        _ -> nil
      end

    max_output_tokens =
      case Keyword.get(opts, :max_output_tokens, 2048) do
        n when is_integer(n) and n > 0 -> n
        _ -> 2048
      end

    payload = %{
      contents: [%{role: "user", parts: [%{text: prompt}]}],
      generationConfig: %{temperature: 0.4, maxOutputTokens: max_output_tokens}
    }

    payload =
      if is_binary(system_prompt) do
        Map.put(payload, :system_instruction, %{parts: [%{text: system_prompt}]})
      else
        payload
      end

    headers = [{~c"content-type", ~c"application/json"}]
    body = Jason.encode!(payload)

    :inets.start()
    :ssl.start()

    case :httpc.request(
           :post,
           {String.to_charlist(url), headers, ~c"application/json", body},
           [{:timeout, timeout}],
           [{:body_format, :binary}]
         ) do
      {:ok, {{_http_version, status, _reason}, _headers, response_body}}
      when status in 200..299 ->
        {:ok, response_body}

      {:ok, {{_http_version, status, _reason}, _headers, response_body}} ->
        {:error, {:http_error, status, response_body}}

      {:error, reason} ->
        {:error, {:http_request_failed, reason}}
    end
  end

  defp parse_text(response_body) when is_binary(response_body) do
    with {:ok, decoded} <- Jason.decode(response_body),
         {:ok, candidates} <- Map.fetch(decoded, "candidates"),
         [first | _] <- candidates,
         %{"content" => %{"parts" => parts}} <- first do
      text =
        parts
        |> Enum.map(&Map.get(&1, "text", ""))
        |> Enum.join("\n")
        |> String.trim()

      if text == "" do
        {:error, :empty_response}
      else
        {:ok, text}
      end
    else
      _ -> {:error, :invalid_response_shape}
    end
  end

  defp fetch_api_key do
    case System.get_env("GEMINI_API_KEY") do
      nil -> {:error, :missing_gemini_api_key}
      "" -> {:error, :missing_gemini_api_key}
      key -> {:ok, key}
    end
  end

  defp chunk_text(text, words_per_chunk) do
    text
    |> String.split(" ")
    |> Enum.chunk_every(words_per_chunk)
    |> Enum.map(&Enum.join(&1, " "))
  end
end
