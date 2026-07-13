defmodule MealPlannerApi.Services.PlanningChatService do
  @moduledoc """
  Planning chat orchestration — menu generation, quick favorites, and proposal flow.

  This service is the new replacement for the tangled PlanningChat + Planning modules.
  It coordinates identity resolution, proposal creation, and the confirm/reject lifecycle.
  """

  require Logger

  alias Ecto.Multi
  alias MealPlannerApi.Data.PlanningRepo
  alias MealPlannerApi.Data.RecipeRepo
  alias MealPlannerApi.Persistence.Identity
  alias MealPlannerApi.Persistence.Planning.PlanningProposal
  alias MealPlannerApi.Persistence.Planning.ScheduledMeal
  alias MealPlannerApi.Repo
  alias MealPlannerApi.Services.BudgetService
  alias MealPlannerApi.Services.PlanningService
  alias MealPlannerApi.Services.ShoppingService

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

  # Post-review fix (CRITICAL item 3, second confirm path): this used to
  # update the proposal to `:accepted` and then insert each scheduled meal
  # independently via `Enum.flat_map`, silently dropping any `{:error, _}`
  # result — the exact same non-atomic bug as `Generation.Server.
  # do_confirm/2`. Now wrapped in the same `Ecto.Multi`/`Repo.transaction`
  # pattern: any failure (proposal update or any one meal insert) rolls back
  # everything.
  @spec confirm_proposal(map(), binary()) :: {:ok, map()} | {:error, term()}
  def confirm_proposal(current_user, proposal_id) when is_binary(proposal_id) do
    with {:ok, ids} <- Identity.ensure_persistent_identity(current_user),
         {:ok, proposal} <-
           PlanningRepo.get_proposal_with_run!(proposal_id) |> then(fn {p, _} -> {:ok, p} end),
         :ok <- verify_ownership(proposal, ids.account_id),
         {:ok, scheduled_meals} <- parse_scheduled_meals(proposal) do
      proposal
      |> build_confirm_multi(scheduled_meals, ids)
      |> Repo.transaction()
      |> handle_confirm_transaction(proposal_id)
    else
      {:error, _} = error -> error
    end
  end

  defp build_confirm_multi(proposal, scheduled_meals, ids) do
    Multi.new()
    |> Multi.update(:proposal, PlanningProposal.changeset(proposal, %{status: :accepted}))
    |> add_scheduled_meal_steps(scheduled_meals, ids)
  end

  defp add_scheduled_meal_steps(multi, scheduled_meals, ids) do
    scheduled_meals
    |> Enum.with_index()
    |> Enum.reduce(multi, fn {meal, index}, acc ->
      Multi.insert(acc, {:scheduled_meal, index}, scheduled_meal_changeset(meal, ids))
    end)
  end

  defp scheduled_meal_changeset(meal, ids) do
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

        %Date{} = d ->
          d

        _ ->
          Date.utc_today()
      end

    %ScheduledMeal{}
    |> ScheduledMeal.changeset(%{
      account_id: ids.account_id,
      date: date_value,
      slot: slot_atom,
      recipe_id: meal["recipe_id"]
    })
  end

  defp handle_confirm_transaction({:ok, changes}, proposal_id) do
    confirmed =
      changes
      |> Enum.filter(fn {key, _} -> match?({:scheduled_meal, _index}, key) end)
      |> Enum.map(fn {_key, meal} -> meal end)

    trigger_shopping_list_sync(changes.proposal, confirmed)

    {:ok,
     %{
       proposal_id: proposal_id,
       generation_run_id: changes.proposal.generation_run_id,
       scheduled_meals_count: length(confirmed),
       scheduled_meals: confirmed
     }}
  end

  defp handle_confirm_transaction({:error, step, reason, _changes_so_far}, proposal_id) do
    log_confirm_transaction_failure(proposal_id, step, reason)
    {:error, :confirm_failed}
  end

  # Item 4: accepting the plan must also load the shopping list with the
  # week's ingredients — eagerly, not just on next lazy read. Runs AFTER the
  # confirm transaction commits (deliberately outside the Multi): if this
  # fails, the confirm itself still stands (meals are safely persisted) and
  # `ShoppingService.get_shopping_list/2`'s existing lazy
  # `ensure_shopping_items_from_schedule/3` call self-heals on next read —
  # only the "eager" convenience is lost, never the confirm.
  defp trigger_shopping_list_sync(_proposal, []), do: :ok

  defp trigger_shopping_list_sync(proposal, confirmed_meals) do
    # `PlanningProposal` itself has no `account_id` (it belongs to a
    # generation_run, not an account directly) — every confirmed
    # `ScheduledMeal` already carries the account_id it was inserted with.
    account_id = hd(confirmed_meals).account_id
    dates = Enum.map(confirmed_meals, & &1.date)
    from_date = Enum.min(dates, Date)
    to_date = Enum.max(dates, Date)
    ShoppingService.ensure_shopping_items_from_schedule(account_id, from_date, to_date)
  rescue
    e ->
      Logger.error(
        "PlanningChatService post-confirm shopping list sync failed proposal_id=#{inspect(proposal.id)} kind=#{inspect(e.__struct__)}"
      )

      :ok
  end

  defp log_confirm_transaction_failure(proposal_id, step, %Ecto.Changeset{errors: errors}) do
    Logger.error(
      "PlanningChatService confirm transaction failed proposal_id=#{inspect(proposal_id)} " <>
        "step=#{inspect(step)} changeset_errors=#{inspect(errors)}"
    )
  end

  defp log_confirm_transaction_failure(proposal_id, step, reason) do
    Logger.error(
      "PlanningChatService confirm transaction failed proposal_id=#{inspect(proposal_id)} " <>
        "step=#{inspect(step)} reason=#{inspect(reason)}"
    )
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
          day_plan
          |> Map.get("meals", [])
          |> Enum.concat(day_plan[:meals] || [])
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
