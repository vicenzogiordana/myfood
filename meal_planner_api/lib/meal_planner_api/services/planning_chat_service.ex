defmodule MealPlannerApi.Services.PlanningChatService do
  @moduledoc """
  Planning chat orchestration — menu generation, quick favorites, and proposal flow.

  This service is the new replacement for the tangled PlanningChat + Planning modules.
  It coordinates identity resolution, proposal creation, and the confirm/reject lifecycle.
  """

  alias MealPlannerApi.Data.PlanningRepo
  alias MealPlannerApi.Data.RecipeRepo
  alias MealPlannerApi.Persistence.Identity
  alias MealPlannerApi.Services.BudgetService
  alias MealPlannerApi.Services.PlanningService

  # -------------------------------------------------------------------------
  # Quick favorites
  # -------------------------------------------------------------------------

  @spec quick_favorites(map(), non_neg_integer()) :: {:ok, [map()]} | {:error, term()}
  def quick_favorites(current_user, limit \\ 10) do
    with {:ok, ids} <- Identity.ensure_persistent_identity(current_user) do
      recipes =
        RecipeRepo.list_favorites(ids.account_id)
        |> Enum.take(limit)
        |> Enum.map(fn recipe ->
          %{
            recipe_id: recipe.id,
            recipe_name: recipe.name,
            slots:
            Enum.map(recipe.suitable_for_slots || [], fn
              slot when is_atom(slot) -> Atom.to_string(slot)
              slot when is_binary(slot) -> slot
            end),
            prep_time_minutes: recipe.prep_time_minutes,
            calories_per_serving: recipe.calories_per_serving
          }
        end)

      {:ok, recipes}
    end
  end

  # -------------------------------------------------------------------------
  # Menu generation
  # -------------------------------------------------------------------------

  @spec generate_menu(map(), map()) :: {:ok, map()} | {:error, term()}
  def generate_menu(current_user, payload) when is_map(payload) do
    with {:ok, ids} <- Identity.ensure_persistent_identity(current_user),
         {:ok, parsed} <- parse_payload(payload),
         budget = BudgetService.resolve(current_user),
         budget_cents = budget.weekly_limit_cents,
         user_with_budget = Map.merge(current_user, %{weekly_budget_cents: budget_cents}),
         {:ok, %{days: plan}} <- PlanningService.generate_weekly_plan(user_with_budget, %{}),
         {:ok, scheduled_meals} <-
           scheduled_meals_from_plan(plan, parsed.date_from, parsed.date_to),
         {:ok, run} <-
           PlanningRepo.create_generation_run(%{
             account_id: ids.account_id,
             user_id: ids.user_id,
             status: :completed,
             started_at: DateTime.utc_now(),
             completed_at: DateTime.utc_now(),
             input_context: %{
               message: parsed.message,
               date_from: Date.to_iso8601(parsed.date_from),
               date_to: Date.to_iso8601(parsed.date_to),
               content_type: parsed.content_type,
               requested_recipe_ids: parsed.requested_recipe_ids,
               weekly_budget_cents: budget_cents
             }
           }),
         proposal_json = build_proposal_json(scheduled_meals, plan, parsed),
         {:ok, proposal} <-
           PlanningRepo.create_proposal(%{
             generation_run_id: run.id,
             proposal_json: proposal_json
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
    merged = Map.merge(base_payload, %{"constraints" => constraint_updates})
    generate_menu(current_user, merged)
  end

  # -------------------------------------------------------------------------
  # Proposal confirmation / rejection
  # -------------------------------------------------------------------------

  @spec confirm_proposal(map(), binary()) :: {:ok, map()} | {:error, term()}
  def confirm_proposal(current_user, proposal_id) when is_binary(proposal_id) do
    with {:ok, ids} <- Identity.ensure_persistent_identity(current_user),
         {:ok, proposal} <-
           PlanningRepo.get_proposal_with_run!(proposal_id) |> then(fn {p, _} -> {:ok, p} end),
         :ok <- verify_ownership(proposal, ids.account_id),
         {:ok, scheduled_meals} <- parse_scheduled_meals(proposal),
         {:ok, _updated} <-
           PlanningRepo.update_proposal(proposal, %{status: :accepted}) do
      confirmed =
        Enum.flat_map(scheduled_meals, fn meal ->
          # Build clean attrs map from string-keyed meal data
          slot_atom =
            meal
            |> Map.get("slot")
            |> case do
              s when is_binary(s) -> String.to_existing_atom(s)
              a when is_atom(a) -> a
              _ -> :dinner
            end

          date_value =
            meal
            |> Map.get("date")
            |> case do
              d when is_binary(d) ->
                case Date.from_iso8601(d) do
                  {:ok, parsed} -> parsed
                  :error -> Date.utc_today()
                end
              %Date{} = d -> d
              _ -> Date.utc_today()
            end

          attrs = %{
            account_id: ids.account_id,
            user_id: ids.user_id,
            date: date_value,
            slot: slot_atom,
            recipe_id: meal["recipe_id"]
          }

          case PlanningRepo.schedule_meal(attrs) do
            {:ok, sm} -> [sm]
            {:error, _} -> []
          end
        end)

      {:ok,
       %{
         proposal_id: proposal_id,
         generation_run_id: proposal.generation_run_id,
         scheduled_meals_count: length(confirmed),
         scheduled_meals: confirmed
       }}
    else
      {:error, _} = error -> error
    end
  end

  @spec reject_proposal(map(), binary()) :: {:ok, map()} | {:error, term()}
  def reject_proposal(current_user, proposal_id) when is_binary(proposal_id) do
    with {:ok, ids} <- Identity.ensure_persistent_identity(current_user),
         {:ok, proposal} <-
           PlanningRepo.get_proposal_with_run!(proposal_id) |> then(fn {p, _} -> {:ok, p} end),
         :ok <- verify_ownership(proposal, ids.account_id),
         {:ok, _updated} <-
           PlanningRepo.update_proposal(proposal, %{status: :rejected}) do
      {:ok,
       %{
         proposal_id: proposal_id,
         generation_run_id: proposal.generation_run_id,
         status: "rejected"
       }}
    else
      {:error, _} = error -> error
    end
  end

  # -------------------------------------------------------------------------
  # Payload parsing
  # -------------------------------------------------------------------------

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

  defp parse_date(nil), do: {:ok, Date.utc_today()}
  defp parse_date(value) when is_binary(value), do: Date.from_iso8601(value)
  defp parse_date(_), do: {:error, :invalid_date}

  defp validate_date_range(date_from, date_to) do
    case Date.compare(date_from, date_to) do
      :lt -> :ok
      :eq -> :ok
      :gt -> {:error, :invalid_date_range}
    end
  end

  defp normalize_message(nil), do: ""
  defp normalize_message(msg) when is_binary(msg), do: String.trim(msg)
  defp normalize_message(_), do: ""

  defp normalize_content_type("speech_transcript"), do: "speech_transcript"
  defp normalize_content_type(_), do: "text"

  defp normalize_recipe_ids(ids) when is_list(ids), do: Enum.filter(ids, &is_binary/1)
  defp normalize_recipe_ids(_), do: []

  # -------------------------------------------------------------------------
  # Plan → scheduled meals conversion
  # -------------------------------------------------------------------------

  defp scheduled_meals_from_plan([], _date_from, _date_to), do: {:ok, []}

  defp scheduled_meals_from_plan(plan, date_from, date_to) when is_list(plan) do
    dates = Enum.to_list(Date.range(date_from, date_to))

    meals =
      dates
      |> Enum.with_index()
      |> Enum.flat_map(fn {date, index} ->
        day_plan = Enum.at(plan, rem(index, length(plan)), %{})

        day_meals =
          (day_plan
           |> Map.get("meals", [])
           |> Enum.concat(day_plan[:meals] || []))
           |> Enum.uniq()

        day_meals
        |> Enum.map(fn meal ->
          # Handle both string-keyed ("slot") and atom-keyed (:slot) maps
          slot = Map.get(meal, "slot") || Map.get(meal, :slot)
          recipe_id = Map.get(meal, "recipe_id") || Map.get(meal, :recipe_id)

          cond do
            not is_binary(slot) ->
              nil

            not is_binary(recipe_id) ->
              nil

            true ->
              %{
                date: Date.to_iso8601(date),
                slot: slot,
                recipe_id: recipe_id
              }
          end
        end)
        |> Enum.reject(&is_nil/1)
      end)

    if meals == [], do: {:ok, []}, else: {:ok, meals}
  end

  defp scheduled_meals_from_plan(_plan, _date_from, _date_to), do: {:ok, []}

  # -------------------------------------------------------------------------
  # Proposal JSON construction
  # -------------------------------------------------------------------------

  defp build_proposal_json(scheduled_meals, plan, parsed) do
    # Build day plans from the plan for the weekly_plan response
    day_plans =
      plan
      |> Enum.with_index()
      |> Enum.map(fn {day_map, _} ->
        %{day: day_map["day"], meals: day_map["meals"] || []}
      end)

    weekly_plan = %{days: day_plans}

    %{
      summary:
        "Propuesta para #{Date.to_iso8601(parsed.date_from)} a #{Date.to_iso8601(parsed.date_to)}",
      date_from: Date.to_iso8601(parsed.date_from),
      date_to: Date.to_iso8601(parsed.date_to),
      user_message: parsed.message,
      scheduled_meals: scheduled_meals,
      weekly_plan: weekly_plan
    }
  end

  defp parse_scheduled_meals(proposal) do
    json = proposal.proposal_json

    meals =
      case Map.get(json, "scheduled_meals", []) do
        list when is_list(list) -> list
        _ -> []
      end

    {:ok, meals}
  rescue
    _ -> {:ok, []}
  end

  defp verify_ownership(proposal, account_id) do
    if proposal.generation_run && proposal.generation_run.account_id == account_id do
      :ok
    else
      {:error, :forbidden}
    end
  end
end
