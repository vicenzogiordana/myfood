defmodule MealPlannerApi.PlanningChat do
  @moduledoc """
  Orchestrates planning chat generation and proposal confirmation flow.
  """

  alias MealPlannerApi.Persistence.Catalog
  alias MealPlannerApi.Persistence.Identity
  alias MealPlannerApi.Persistence.Planning

  @slots [:lunch, :dinner]

  @spec quick_favorites(map(), non_neg_integer()) :: {:ok, [map()]} | {:error, term()}
  def quick_favorites(current_user, limit \\ 10) do
    with {:ok, ids} <- Identity.ensure_persistent_identity(current_user) do
      {:ok, Planning.list_favorite_recipes_for_user(ids.account_id, ids.user_id, limit)}
    end
  end

  @spec generate_menu(map(), map()) :: {:ok, map()} | {:error, term()}
  def generate_menu(current_user, payload) when is_map(payload) do
    with {:ok, ids} <- Identity.ensure_persistent_identity(current_user),
         {:ok, parsed} <- parse_payload(payload),
         {:ok, run} <- create_run(ids, parsed, current_user),
         proposal_json <- build_proposal(ids.account_id, parsed),
         {:ok, proposal} <-
           Planning.create_proposal(%{generation_run_id: run.id, proposal_json: proposal_json}),
         {:ok, _updated_run} <-
           Planning.update_generation_run(run, %{
             status: :completed,
             completed_at: DateTime.utc_now()
           }) do
      {:ok,
       %{
         run: run,
         proposal: proposal,
         proposal_json: proposal_json,
         date_from: parsed.date_from,
         date_to: parsed.date_to
       }}
    else
      {:error, _} = error -> error
    end
  end

  @spec confirm_proposal(map(), binary()) :: {:ok, map()} | {:error, term()}
  def confirm_proposal(current_user, proposal_id) when is_binary(proposal_id) do
    with {:ok, ids} <- Identity.ensure_persistent_identity(current_user),
         {:ok, result} <- Planning.confirm_proposal(ids.account_id, ids.user_id, proposal_id) do
      {:ok, result}
    end
  end

  @spec reject_proposal(map(), binary()) :: {:ok, map()} | {:error, term()}
  def reject_proposal(current_user, proposal_id) when is_binary(proposal_id) do
    with {:ok, ids} <- Identity.ensure_persistent_identity(current_user),
         {:ok, result} <- Planning.reject_proposal(ids.account_id, ids.user_id, proposal_id) do
      {:ok, result}
    end
  end

  defp create_run(ids, parsed, current_user) do
    Planning.create_generation_run(%{
      account_id: ids.account_id,
      user_id: ids.user_id,
      status: :processing,
      started_at: DateTime.utc_now(),
      input_context: %{
        message: parsed.message,
        date_from: Date.to_iso8601(parsed.date_from),
        date_to: Date.to_iso8601(parsed.date_to),
        content_type: parsed.content_type,
        requested_recipe_ids: parsed.requested_recipe_ids,
        external_user_id: Map.get(current_user, :id),
        external_account_id: Map.get(current_user, :account_id)
      }
    })
  end

  defp build_proposal(account_id, parsed) do
    favorites_by_slot =
      parsed.requested_recipe_ids
      |> Planning.recipes_for_ids(account_id)
      |> Enum.group_by(& &1.slot)

    slot_pool =
      Enum.reduce(@slots, %{}, fn slot, acc ->
        pool =
          case Map.get(favorites_by_slot, slot, []) do
            [] ->
              Catalog.recipes_for_slot(account_id, slot)
              |> Enum.map(&recipe_ref(&1, slot))

            favorites ->
              favorites
          end

        Map.put(acc, slot, if(pool == [], do: [fallback_recipe(slot)], else: pool))
      end)

    meals =
      parsed.date_from
      |> Date.range(parsed.date_to)
      |> Enum.to_list()
      |> Enum.flat_map(fn date ->
        Enum.map(@slots, fn slot ->
          recipe = pick_recipe(Map.fetch!(slot_pool, slot), date, slot)

          %{
            date: Date.to_iso8601(date),
            slot: Atom.to_string(slot),
            recipe_id: recipe.id,
            recipe_name: recipe.name,
            servings: 2,
            notes: "Generado por pipeline (optimización + refinamiento)",
            source: recipe.source
          }
        end)
      end)

    %{
      summary:
        "Propuesta para #{Date.to_iso8601(parsed.date_from)} a #{Date.to_iso8601(parsed.date_to)}",
      date_from: Date.to_iso8601(parsed.date_from),
      date_to: Date.to_iso8601(parsed.date_to),
      user_message: parsed.message,
      scheduled_meals: meals,
      shopping_hints: shopping_hints(meals),
      pipeline: %{
        stage_1_data_gathering: "done",
        stage_2_math_optimization: "simulated",
        stage_3_llm_refinement: "simulated",
        stage_4_structured_output: "done"
      }
    }
  end

  defp parse_payload(payload) do
    with {:ok, date_from} <- parse_date(Map.get(payload, "date_from")),
         {:ok, date_to} <- parse_date(Map.get(payload, "date_to")),
         :ok <- validate_date_range(date_from, date_to) do
      {:ok,
       %{
         message: normalize_message(Map.get(payload, "message")),
         content_type: normalize_content_type(Map.get(payload, "content_type")),
         requested_recipe_ids: normalize_recipe_ids(Map.get(payload, "requested_recipe_ids", [])),
         date_from: date_from,
         date_to: date_to
       }}
    end
  end

  defp parse_date(value) when is_binary(value), do: Date.from_iso8601(value)
  defp parse_date(_), do: {:error, :invalid_date}

  defp validate_date_range(date_from, date_to) do
    if Date.compare(date_from, date_to) in [:lt, :eq] do
      :ok
    else
      {:error, :invalid_date_range}
    end
  end

  defp normalize_message(message) when is_binary(message), do: String.trim(message)
  defp normalize_message(_), do: ""

  defp normalize_content_type("speech_transcript"), do: "speech_transcript"
  defp normalize_content_type(_), do: "text"

  defp normalize_recipe_ids(recipe_ids) when is_list(recipe_ids) do
    Enum.filter(recipe_ids, &is_binary/1)
  end

  defp normalize_recipe_ids(_), do: []

  defp recipe_ref(recipe, slot) do
    %{id: recipe.id, name: recipe.name, slot: slot, source: "favorite"}
  end

  defp fallback_recipe(slot) do
    %{id: nil, name: "Sugerencia sin receta guardada", slot: slot, source: "fallback"}
  end

  defp pick_recipe(pool, date, slot) do
    day_index = Date.day_of_year(date)
    slot_offset = if(slot == :lunch, do: 0, else: 1)
    index = rem(day_index + slot_offset, length(pool))
    Enum.at(pool, index)
  end

  defp shopping_hints(meals) do
    ingredient_count =
      meals
      |> Enum.map(&Map.get(&1, :recipe_name))
      |> Enum.reject(&is_nil/1)
      |> Enum.frequencies()
      |> map_size()

    [
      %{
        title: "Lista preliminar",
        detail: "Basada en #{ingredient_count} recetas propuestas",
        status: "draft"
      }
    ]
  end
end
