defmodule MealPlannerApi.AI.GeminiClient do
  @moduledoc """
  Gemini AI client used for both streamed chat (true HTTP streaming) and sync generation.
  """

  @behaviour MealPlannerApi.AI.Client

  alias MealPlannerApiWeb.Endpoint

  @default_model "gemini-2.5-flash-lite"
  @default_base_url "https://generativelanguage.googleapis.com"

  @impl true
  def stream_chat_completion(topic, prompt, opts) do
    request_id = Keyword.get(opts, :request_id) || "req_stream"
    account_id = get_in(opts, [:user, :account_id])

    Task.start(fn ->
      Endpoint.broadcast(topic, "ai_response_started", %{
        request_id: request_id,
        account_id: account_id
      })

      case do_stream_generate(prompt, opts) do
        {:ok, http_request_id} ->
          stream_loop(topic, request_id, account_id, http_request_id, "")

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

  defp do_stream_generate(prompt, opts) do
    with {:ok, api_key} <- fetch_api_key() do
      model = Application.get_env(:meal_planner_api, :gemini_model, @default_model)
      base_url = Application.get_env(:meal_planner_api, :gemini_base_url, @default_base_url)

      url =
        base_url <> "/v1beta/models/" <> model <> ":streamGenerateContent?alt=sse&key=" <> URI.encode(api_key)

      {headers, body} = build_request(prompt, opts)

      :inets.start()
      :ssl.start()

      case :httpc.request(
             :post,
             {String.to_charlist(url), headers, ~c"application/json", body},
             [{:timeout, 30_000}],
             [{:sync, false}, {:stream, :self}, {:body_format, :binary}]
           ) do
        {:ok, request_id} -> {:ok, request_id}
        {:error, reason} -> {:error, {:http_request_failed, reason}}
      end
    end
  end

  defp stream_loop(topic, request_id, account_id, http_request_id, buffer) do
    receive do
      {:http, {^http_request_id, :stream, bin}} ->
        new_buffer = buffer <> bin
        remaining_buffer = process_sse_buffer(topic, request_id, account_id, new_buffer)
        stream_loop(topic, request_id, account_id, http_request_id, remaining_buffer)

      {:http, {^http_request_id, :stream_end, _headers}} ->
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

      {:http, {^http_request_id, {:error, reason}}} ->
        Endpoint.broadcast(topic, "ai_response_error", %{
          request_id: request_id,
          account_id: account_id,
          error: inspect(reason)
        })
    after
      30_000 ->
        Endpoint.broadcast(topic, "ai_response_error", %{
          request_id: request_id,
          account_id: account_id,
          error: "stream_timeout"
        })
    end
  end

  defp process_sse_buffer(topic, request_id, account_id, buffer) do
    case String.split(buffer, "\n\n", parts: 2) do
      [event, rest] ->
        if String.starts_with?(event, "data: ") do
          data_json = String.replace_prefix(event, "data: ", "")
          
          if data_json != "[DONE]" do
             case Jason.decode(data_json) do
               {:ok, decoded} ->
                 case Map.fetch(decoded, "candidates") do
                   {:ok, [first | _]} ->
                     case get_in(first, ["content", "parts"]) do
                       [%{"text" => text} | _] ->
                         Endpoint.broadcast(topic, "ai_response_chunk", %{
                           request_id: request_id,
                           account_id: account_id,
                           chunk: text,
                           done: false
                         })
                       _ -> :ok
                     end
                   _ -> :ok
                 end
               _ -> :ok
             end
          end
        end
        process_sse_buffer(topic, request_id, account_id, rest)

      [incomplete] ->
        incomplete
    end
  end

  defp do_generate(prompt, opts, api_key) do
    model = Application.get_env(:meal_planner_api, :gemini_model, @default_model)
    base_url = Application.get_env(:meal_planner_api, :gemini_base_url, @default_base_url)
    timeout = Application.get_env(:meal_planner_api, :gemini_timeout_ms, 15_000)

    url =
      base_url <> "/v1beta/models/" <> model <> ":generateContent?key=" <> URI.encode(api_key)

    {headers, body} = build_request(prompt, opts)

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

  defp build_request(prompt, opts) do
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
    {headers, body}
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
end
