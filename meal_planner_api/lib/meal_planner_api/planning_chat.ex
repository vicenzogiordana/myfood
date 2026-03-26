defmodule MealPlannerApi.PlanningChat do
  @moduledoc """
  Orchestrates planning chat generation and proposal confirmation flow.
  """

  alias MealPlannerApi.Planning, as: PlanningEngine
  alias MealPlannerApi.Persistence.Identity
  alias MealPlannerApi.Persistence.Planning, as: PlanningPersistence

  @spec quick_favorites(map(), non_neg_integer()) :: {:ok, [map()]} | {:error, term()}
  def quick_favorites(current_user, limit \\ 10) do
    with {:ok, ids} <- Identity.ensure_persistent_identity(current_user) do
      {:ok,
       PlanningPersistence.list_favorite_recipes_for_user(ids.account_id, ids.user_id, limit)}
    end
  end

  @spec generate_menu(map(), map()) :: {:ok, map()} | {:error, term()}
  def generate_menu(current_user, payload) when is_map(payload) do
    with {:ok, ids} <- Identity.ensure_persistent_identity(current_user),
         {:ok, parsed} <- parse_payload(payload),
         {:ok, run} <- create_run(ids, parsed, current_user),
         {:ok, proposal_json} <- build_proposal_from_engine(current_user, parsed),
         {:ok, proposal} <-
           PlanningPersistence.create_proposal(%{
             generation_run_id: run.id,
             proposal_json: proposal_json
           }),
         {:ok, _updated_run} <-
           PlanningPersistence.update_generation_run(run, %{
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

  @spec regenerate_menu(map(), map(), map()) :: {:ok, map()} | {:error, term()}
  def regenerate_menu(current_user, base_payload, constraint_updates)
      when is_map(base_payload) and is_map(constraint_updates) do
    merged_payload = merge_constraint_updates(base_payload, constraint_updates)
    generate_menu(current_user, merged_payload)
  end

  @spec confirm_proposal(map(), binary()) :: {:ok, map()} | {:error, term()}
  def confirm_proposal(current_user, proposal_id) when is_binary(proposal_id) do
    with {:ok, ids} <- Identity.ensure_persistent_identity(current_user),
         {:ok, result} <-
           PlanningPersistence.confirm_proposal(ids.account_id, ids.user_id, proposal_id) do
      {:ok, result}
    end
  end

  @spec reject_proposal(map(), binary()) :: {:ok, map()} | {:error, term()}
  def reject_proposal(current_user, proposal_id) when is_binary(proposal_id) do
    with {:ok, ids} <- Identity.ensure_persistent_identity(current_user),
         {:ok, result} <-
           PlanningPersistence.reject_proposal(ids.account_id, ids.user_id, proposal_id) do
      {:ok, result}
    end
  end

  defp create_run(ids, parsed, current_user) do
    PlanningPersistence.create_generation_run(%{
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
        planning_params: parsed.planning_params,
        external_user_id: Map.get(current_user, :id),
        external_account_id: Map.get(current_user, :account_id)
      }
    })
  end

  defp build_proposal_from_engine(current_user, parsed) do
    with {:ok, weekly_plan} <-
           PlanningEngine.weekly_plan_for(current_user, parsed.planning_params),
         serialized_plan = PlanningEngine.serialize_plan(weekly_plan),
         {:ok, scheduled_meals} <-
           scheduled_meals_from_weekly_plan(serialized_plan, parsed.date_from, parsed.date_to) do
      {:ok,
       %{
         summary:
           "Propuesta para #{Date.to_iso8601(parsed.date_from)} a #{Date.to_iso8601(parsed.date_to)}",
         date_from: Date.to_iso8601(parsed.date_from),
         date_to: Date.to_iso8601(parsed.date_to),
         user_message: parsed.message,
         scheduled_meals: scheduled_meals,
         weekly_plan: serialized_plan,
         shopping_hints: shopping_hints(scheduled_meals)
       }}
    end
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
         planning_params: extract_planning_params(payload),
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

  defp extract_planning_params(payload) do
    ["kcal_target", "weekly_budget_cents", "currency", "days"]
    |> Enum.reduce(%{}, fn key, acc ->
      case Map.get(payload, key) do
        nil -> acc
        "" -> acc
        value -> Map.put(acc, key, value)
      end
    end)
  end

  defp merge_constraint_updates(base_payload, constraint_updates) do
    base_constraints =
      base_payload
      |> Map.get("constraints", %{})
      |> normalize_constraint_map()

    merged_constraints = Map.merge(base_constraints, normalize_constraint_map(constraint_updates))

    base_payload
    |> Map.merge(merged_constraints)
    |> Map.put("constraints", merged_constraints)
  end

  defp normalize_constraint_map(updates) when is_map(updates) do
    ["kcal_target", "weekly_budget_cents", "currency", "days"]
    |> Enum.reduce(%{}, fn key, acc ->
      case Map.get(updates, key) do
        nil -> acc
        "" -> acc
        value -> Map.put(acc, key, value)
      end
    end)
  end

  defp scheduled_meals_from_weekly_plan(serialized_plan, date_from, date_to) do
    days = Map.get(serialized_plan, :days, [])
    dates = Enum.to_list(Date.range(date_from, date_to))

    if days == [] do
      {:error, :empty_generated_plan}
    else
      meals =
        dates
        |> Enum.with_index()
        |> Enum.flat_map(fn {date, index} ->
          day_plan = Enum.at(days, rem(index, length(days)), %{})
          day_meals = Map.get(day_plan, :meals, [])

          day_meals
          |> Enum.map(fn meal ->
            slot = Map.get(meal, :slot)
            recipe_id = Map.get(meal, :recipe_id)

            cond do
              not is_atom(slot) ->
                nil

              not is_binary(recipe_id) ->
                nil

              true ->
                %{
                  date: Date.to_iso8601(date),
                  slot: Atom.to_string(slot),
                  recipe_id: recipe_id,
                  recipe_name: Map.get(meal, :label)
                }
            end
          end)
          |> Enum.reject(&is_nil/1)
        end)

      if meals == [] do
        {:error, :empty_generated_plan}
      else
        {:ok, meals}
      end
    end
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
