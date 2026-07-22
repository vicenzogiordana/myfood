defmodule MealPlannerApi.Services.GenerationService do
  @moduledoc """
  Pure stateless functions used by GenerationServer during the planning pipeline.

  This module has no side effects. All DB writes and HTTP calls are done by the
  caller (GenerationServer). This separation makes GenerationServer testable.
  """

  # -------------------------------------------------------------------------
  # Constraints
  # -------------------------------------------------------------------------

  @doc """
  Builds the resolved constraints map by merging user profile defaults
  with payload overrides from the channel message.

  Profile values are used when payload does not provide them.
  """
  @spec build_constraints(map(), map() | nil) :: map()
  def build_constraints(user_profile, nil) do
    %{
      protein_g_per_meal: Map.get(user_profile, :protein_g_per_meal, 25),
      budget_cents: Map.get(user_profile, :default_budget_cents, 10_000),
      max_calories: Map.get(user_profile, :max_calories, 800),
      excluded_recipe_ids: Map.get(user_profile, :excluded_recipe_ids, []),
      excluded_ingredients: Map.get(user_profile, :default_exclusions, []),
      favorite_recipe_ids: []
    }
  end

  def build_constraints(user_profile, payload) do
    resolved = build_constraints(user_profile, nil)

    payload_exclusions = payload["excluded_ingredients"] || payload[:excluded_ingredients] || []

    %{
      resolved
      | protein_g_per_meal:
          payload["protein_g"] || payload[:protein_g] || resolved.protein_g_per_meal,
        budget_cents: payload["budget_cents"] || payload[:budget_cents] || resolved.budget_cents,
        max_calories: payload["max_calories"] || payload[:max_calories] || resolved.max_calories,
        excluded_recipe_ids:
          payload["excluded_recipe_ids"] || payload[:excluded_recipe_ids] ||
            resolved.excluded_recipe_ids,
        excluded_ingredients: payload_exclusions ++ resolved.excluded_ingredients,
        favorite_recipe_ids:
          payload["favorite_recipe_ids"] || payload[:favorite_recipe_ids] ||
            resolved.favorite_recipe_ids
    }
  end

  @doc """
  Validates that constraints are within acceptable ranges.

  Returns `:ok` or `{:error, :invalid_constraints}` with details.
  """
  @spec validate_constraints(map()) :: :ok | {:error, :invalid_constraints, map()}
  def validate_constraints(constraints) do
    errors =
      []
      |> check_constraints(:protein_g_per_meal, Map.get(constraints, :protein_g_per_meal, 0))
      |> check_constraints(:budget_cents, Map.get(constraints, :budget_cents, 0))
      |> check_constraints(:max_calories, Map.get(constraints, :max_calories, 0))

    case errors do
      [] -> :ok
      _ -> {:error, :invalid_constraints, %{errors: errors}}
    end
  end

  # -------------------------------------------------------------------------
  # Slot key
  # -------------------------------------------------------------------------

  @doc """
  Formats a slot key as \"YYYY-MM-DD_slot\" for broadcasts and state keys.

      iex> slot_key("2026-06-03", :lunch)
      "2026-06-03_lunch"
  """
  @spec slot_key(String.t(), atom()) :: String.t()
  def slot_key(date, slot) when is_binary(date) and is_atom(slot) do
    "#{date}_#{slot}"
  end

  @doc "Parses a slot_key back into {date, slot}."
  @spec parse_slot_key(String.t()) :: {String.t(), atom()}
  def parse_slot_key(slot_key) when is_binary(slot_key) do
    [date, slot] = String.split(slot_key, "_", parts: 2)
    {date, String.to_existing_atom(slot)}
  end

  # -------------------------------------------------------------------------
  # Modification parsing
  # -------------------------------------------------------------------------

  @doc """
  Parses a user chat message to extract a slot modification intent.

  Returns `{:ok, %{slot_key, change_type, new_value}}` or `{:error, :invalid_modification}`.

  Supported patterns:
  - "cambia el almuerzo del martes por algo más barato"
  - "saca las recetas con pollo"
  - "quiero algo sin gluten el miércoles"
  - "cambia dinner 2026-06-04"
  """
  @spec parse_modification(String.t()) :: {:ok, map()} | {:error, :invalid_modification}
  def parse_modification(message) when is_binary(message) do
    msg = String.downcase(message)

    cond do
      # Pattern: "cambia el [slot] del [date/今日]"
      Regex.match?(~r/cambia|change|modifica/, msg) ->
        parse_slot_change(msg)

      # Pattern: "sin [ingredient]" or "saca [ingredient]"
      Regex.match?(~r/sin |saca |quitale /, msg) ->
        parse_ingredient_removal(msg)

      # Pattern: "más barato| cheaper | lower price"
      Regex.match?(~r/más barato|más económico|cheaper|lower price/, msg) ->
        {:ok, %{slot_key: nil, change_type: :lower_price, new_value: nil}}

      # Pattern: "más proteina|more protein"
      Regex.match?(~r/más proteína|more protein/, msg) ->
        {:ok, %{slot_key: nil, change_type: :higher_protein, new_value: nil}}

      true ->
        {:error, :invalid_modification}
    end
  rescue
    _ -> {:error, :invalid_modification}
  end

  # -------------------------------------------------------------------------
  # Proposal building
  # -------------------------------------------------------------------------

  @doc """
  Serializes a list of resolved slots into the proposal JSON structure.

  The proposal_json is what gets persisted to DB and sent in `proposal_ready`.
  """
  @spec build_proposal_json([map()]) :: map()
  def build_proposal_json(resolved_slots) when is_list(resolved_slots) do
    %{
      slots:
        Enum.map(resolved_slots, fn slot ->
          %{
            slot_key: slot_key(slot["date"] || slot[:date], slot["slot"] || slot[:slot]),
            recipe_id: slot["recipe_id"] || slot[:recipe_id],
            recipe_name: slot["recipe_name"] || slot[:recipe_name],
            price_cents: slot["price_cents"] || slot[:price_cents],
            macros:
              (slot["macros"] || slot[:macros] || %{})
              |> Enum.into(%{}, fn {k, v} -> {to_string(k), v} end)
          }
        end),
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  @doc """
  Extracts shopping items from the shopping_items_json field.

  Returns a flat list of `{ingredient_name, quantity, unit, estimated_price_cents}` tuples.
  """
  @spec parse_shopping_items(map() | nil) :: [map()]
  def parse_shopping_items(nil), do: []

  def parse_shopping_items(items) when is_map(items) do
    Enum.map(items, fn
      {_, item} when is_map(item) ->
        %{
          ingredient_name: Map.get(item, "name") || Map.get(item, :name, ""),
          quantity: Map.get(item, "quantity") || Map.get(item, :quantity, 1),
          unit: Map.get(item, "unit") || Map.get(item, :unit, "unit"),
          estimated_price_cents: Map.get(item, "price_cents") || Map.get(item, :price_cents, 0)
        }

      item when is_map(item) ->
        %{
          ingredient_name: Map.get(item, "name") || Map.get(item, :name, ""),
          quantity: Map.get(item, "quantity") || Map.get(item, :quantity, 1),
          unit: Map.get(item, "unit") || Map.get(item, :unit, "unit"),
          estimated_price_cents: Map.get(item, "price_cents") || Map.get(item, :price_cents, 0)
        }
    end)
  end

  # -------------------------------------------------------------------------
  # Shopping cart aggregation
  # -------------------------------------------------------------------------

  @doc """
  Builds per-scheduled-meal cart lines from a confirmed proposal's scheduled
  meals and their recipes' ingredients.

  `by_recipe` is `%{recipe_id => [%{ingredient_id, unit, quantity_milli}]}`,
  as returned by `Data.RecipeRepo.list_ingredients_for_recipes/1`.

  A meal with a `nil` `recipe_id`, or whose `recipe_id` is absent from
  `by_recipe` (no `recipe_ingredients`), contributes no lines.

  No cross-meal summing — one line per `(scheduled_meal_id, ingredient_id,
  unit)`. Pure function, no DB/Repo calls.
  """
  @spec build_cart_lines([map()], %{term() => [map()]}) :: [map()]
  def build_cart_lines(scheduled_meals, by_recipe)
      when is_list(scheduled_meals) and is_map(by_recipe) do
    Enum.flat_map(scheduled_meals, fn meal ->
      case meal.recipe_id do
        nil ->
          []

        recipe_id ->
          by_recipe
          |> Map.get(recipe_id, [])
          |> Enum.map(fn recipe_ingredient ->
            %{
              scheduled_meal_id: meal.id,
              planned_date: meal.date,
              ingredient_id: recipe_ingredient.ingredient_id,
              unit: recipe_ingredient.unit,
              quantity_milli: recipe_ingredient.quantity_milli
            }
          end)
      end
    end)
  end

  @doc """
  Groups cart lines by `{ingredient_id, unit}` and sums `quantity_milli`.

  Read-time dedup/summary — no unit conversion (same ingredient in different
  units stays as separate summary lines). Pure function.
  """
  @spec summarize_cart([map()]) :: [map()]
  def summarize_cart(cart_lines) when is_list(cart_lines) do
    cart_lines
    |> Enum.group_by(&{&1.ingredient_id, &1.unit})
    |> Enum.map(fn {{ingredient_id, unit}, lines} ->
      %{
        ingredient_id: ingredient_id,
        unit: unit,
        quantity_milli: Enum.sum(Enum.map(lines, & &1.quantity_milli))
      }
    end)
  end

  # -------------------------------------------------------------------------
  # Private helpers
  # -------------------------------------------------------------------------

  defp check_constraints(errors, key, value) when is_number(value) and value < 0,
    do: [{key, "must be non-negative"} | errors]

  defp check_constraints(errors, :protein_g_per_meal, value) when value > 200,
    do: [{:protein_g_per_meal, "must be 0–200g"} | errors]

  defp check_constraints(errors, :budget_cents, value) when value > 100_000,
    do: [{:budget_cents, "must be 0–100,000 cents ($1,000)"} | errors]

  defp check_constraints(errors, :max_calories, value) when value > 3000,
    do: [{:max_calories, "must be 0–3000 kcal"} | errors]

  defp check_constraints(errors, _, _), do: errors

  defp parse_slot_change(msg) do
    date =
      case Regex.run(~r/\d{4}-\d{2}-\d{2}/, msg) do
        [d] -> d
        _ -> extract_day_of_week(msg) || Date.utc_today() |> Date.to_iso8601()
      end

    slot =
      cond do
        Regex.run(~r/desayuno|breakfast/, msg) -> :breakfast
        Regex.run(~r/almuerzo|lunch/, msg) -> :lunch
        Regex.run(~r/cena|dinner/, msg) -> :dinner
        Regex.run(~r/snack/, msg) -> :snack
        true -> nil
      end

    {:ok, %{slot_key: slot_key(date, slot), change_type: :change_recipe, new_value: nil}}
  end

  defp parse_ingredient_removal(msg) do
    ingredient =
      msg
      |> String.replace(~r/^(sin |saca |quitale )/, "")
      |> String.trim()
      |> String.split(~r/[,\.]/)
      |> List.first()
      |> String.trim()

    {:ok, %{slot_key: nil, change_type: :remove_ingredient, new_value: ingredient}}
  end

  defp extract_day_of_week(msg) do
    day_map = %{
      "lunes" => :monday,
      "monday" => :monday,
      "martes" => :tuesday,
      "tuesday" => :tuesday,
      "miércoles" => :wednesday,
      "wednesday" => :wednesday,
      "jueves" => :thursday,
      "thursday" => :thursday,
      "viernes" => :friday,
      "friday" => :friday,
      "sábado" => :saturday,
      "saturday" => :saturday,
      "domingo" => :sunday,
      "sunday" => :sunday
    }

    Enum.find_value(day_map, fn {word, _} ->
      if String.contains?(msg, word), do: day_of_week_to_date(word)
    end)
  end

  defp day_of_week_to_date(day_key) do
    today = Date.utc_today()

    target =
      Map.fetch!(
        %{
          "monday" => 1,
          "tuesday" => 2,
          "wednesday" => 3,
          "thursday" => 4,
          "friday" => 5,
          "saturday" => 6,
          "sunday" => 7
        },
        day_key
      )

    current = Date.day_of_week(today)
    diff = target - current
    Date.add(today, if(diff < 0, do: diff + 7, else: diff)) |> Date.to_iso8601()
  end
end
