#!/bin/bash
# Remove from persistence
sed -i '' '/def confirm_proposal/,/^  defp parse_meal_slot(_), do: {:error, :invalid_slot}/d' meal_planner_api/lib/meal_planner_api/persistence/planning.ex

# Ensure fetch_owned_proposal is public
sed -i '' 's/defp fetch_owned_proposal/def fetch_owned_proposal/' meal_planner_api/lib/meal_planner_api/persistence/planning.ex
