defmodule MealPlannerApi.AI.MockClient do
  @moduledoc """
  Mock AI provider that emits chunked responses over a Phoenix topic.
  """

  @behaviour MealPlannerApi.AI.Client

  alias MealPlannerApiWeb.Endpoint

  @impl true
  def stream_chat_completion(topic, prompt, opts) do
    Task.start(fn ->
      request_id = Keyword.get(opts, :request_id) || "req_stream"
      account_id = get_in(opts, [:user, :account_id])

      Endpoint.broadcast(topic, "ai_response_started", %{
        request_id: request_id,
        account_id: account_id
      })

      try do
        chunks =
          prompt
          |> build_response_text(opts)
          |> chunk_text(5)

        Enum.each(chunks, fn chunk ->
          Process.sleep(120)

          payload = %{
            request_id: request_id,
            account_id: account_id,
            chunk: chunk,
            done: false
          }

          Endpoint.broadcast(topic, "ai_response_chunk", payload)
        end)

        Endpoint.broadcast(topic, "ai_response_chunk", %{
          request_id: request_id,
          account_id: account_id,
          chunk: "",
          done: true
        })

        Endpoint.broadcast(topic, "ai_response_finished", %{
          request_id: request_id,
          account_id: account_id,
          total_chunks: length(chunks)
        })
      rescue
        error ->
          Endpoint.broadcast(topic, "ai_response_error", %{
            request_id: request_id,
            account_id: account_id,
            error: Exception.message(error)
          })
      end
    end)

    :ok
  end

  defp build_response_text(prompt, opts) do
    budget = get_in(opts, [:budget, :weekly_limit_cents]) || 45_000
    currency = get_in(opts, [:budget, :currency]) || "ARS"
    inventory_items = opts |> Keyword.get(:inventory_items, []) |> Enum.join(", ")

    "Mock AI says: '#{prompt}'. Respect weekly budget #{budget} #{currency} cents, prioritize inventory [#{inventory_items}], and keep prep fast with low waste."
  end

  defp chunk_text(text, words_per_chunk) do
    text
    |> String.split(" ")
    |> Enum.chunk_every(words_per_chunk)
    |> Enum.map(&Enum.join(&1, " "))
  end
end
