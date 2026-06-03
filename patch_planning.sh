#!/bin/bash
cat << 'INNER_EOF' >> meal_planner_api/lib/meal_planner_api/planning.ex

  def confirm_proposal(account_id, user_id, proposal_id) do
    with {:ok, proposal, run} <- PlanningPersistence.fetch_owned_proposal(proposal_id, account_id, user_id),
         {:ok, meals} <- parse_scheduled_meals(proposal.proposal_json) do
      Multi.new()
      |> Multi.update(
        :proposal,
        MealPlannerApi.Persistence.Planning.PlanningProposal.changeset(proposal, %{status: :accepted})
      )
      |> Multi.update(
        :run,
        MealPlannerApi.Persistence.Planning.PlanningGenerationRun.changeset(run, %{
          status: :completed,
          completed_at: DateTime.utc_now()
        })
      )
      |> Multi.run(:scheduled_meals, fn repo, _changes ->
        upsert_scheduled_meals(repo, account_id, run.id, meals)
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{scheduled_meals: inserted}} ->
          {:ok,
           %{
             proposal_id: proposal.id,
             generation_run_id: run.id,
             scheduled_meals_count: length(inserted)
           }}

        {:error, _step, reason, _changes} ->
          {:error, reason}
      end
    end
  end

  def reject_proposal(account_id, user_id, proposal_id) do
    with {:ok, proposal, run} <- PlanningPersistence.fetch_owned_proposal(proposal_id, account_id, user_id),
         {:ok, _proposal} <- PlanningPersistence.update_proposal(proposal, %{status: :rejected}),
         {:ok, _run} <-
           PlanningPersistence.update_generation_run(run, %{status: :completed, completed_at: DateTime.utc_now()}) do
      {:ok, %{proposal_id: proposal.id, generation_run_id: run.id}}
    end
  end

  defp parse_scheduled_meals(%{"scheduled_meals" => meals}) when is_list(meals) do
    meals
    |> Enum.reduce_while({:ok, []}, fn raw, {:ok, acc} ->
      with {:ok, date} <- parse_meal_date(Map.get(raw, "date")),
           {:ok, slot} <- parse_meal_slot(Map.get(raw, "slot")) do
        parsed = %{date: date, slot: slot, recipe_id: Map.get(raw, "recipe_id")}
        {:cont, {:ok, [parsed | acc]}}
      else
        _ -> {:halt, {:error, :invalid_proposal_payload}}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      {:error, _} = error -> error
    end
  end

  defp parse_scheduled_meals(_), do: {:error, :invalid_proposal_payload}

  defp upsert_scheduled_meals(repo, account_id, generation_run_id, meals) do
    Enum.reduce_while(meals, {:ok, []}, fn meal, {:ok, acc} ->
      attrs = %{
        account_id: account_id,
        date: meal.date,
        slot: meal.slot,
        recipe_id: meal.recipe_id,
        ai_generation_id: generation_run_id,
        is_cooked: false
      }

      changeset = ScheduledMeal.changeset(%ScheduledMeal{}, attrs)

      case repo.insert(changeset,
             on_conflict: [set: [recipe_id: meal.recipe_id, ai_generation_id: generation_run_id]],
             conflict_target: [:account_id, :date, :slot],
             returning: true
           ) do
        {:ok, inserted} -> {:cont, {:ok, [inserted | acc]}}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      {:error, _} = error -> error
    end
  end

  defp parse_meal_date(value) when is_binary(value), do: Date.from_iso8601(value)
  defp parse_meal_date(_), do: {:error, :invalid_date}

  defp parse_meal_slot("breakfast"), do: {:ok, :breakfast}
  defp parse_meal_slot("lunch"), do: {:ok, :lunch}
  defp parse_meal_slot("snack"), do: {:ok, :snack}
  defp parse_meal_slot("dinner"), do: {:ok, :dinner}
  defp parse_meal_slot(_), do: {:error, :invalid_slot}
INNER_EOF

# Fix the trailing "end" which was pushed down
sed -i '' '/defp parse_meal_slot(_), do: {:error, :invalid_slot}/!b; n; c\
end' meal_planner_api/lib/meal_planner_api/planning.ex
# Remove the old end
sed -i '' '/^end$/d' meal_planner_api/lib/meal_planner_api/planning.ex
echo "end" >> meal_planner_api/lib/meal_planner_api/planning.ex
