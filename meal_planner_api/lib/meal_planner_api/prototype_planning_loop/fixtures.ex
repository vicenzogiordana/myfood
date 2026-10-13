# Throwaway prototype for issue #88 (bounded planning loop). Not production code.
defmodule MealPlannerApi.PrototypePlanningLoop.Fixtures do
  @moduledoc """
  Fictitious households, recipe catalogue and prices. Everything here is made
  up: no real user data, no database, no internet.
  """

  @days ~w(mon tue wed thu fri sat sun)
  @slots ~w(breakfast lunch dinner)

  # Price in cents per purchase unit of each ingredient.
  @prices %{
    "oats" => 60,
    "milk" => 90,
    "banana" => 40,
    "eggs" => 35,
    "bread" => 30,
    "peanut_butter" => 80,
    "yogurt" => 110,
    "rice" => 70,
    "chicken" => 320,
    "lentils" => 120,
    "tomato" => 60,
    "pasta" => 90,
    "beef" => 450,
    "tortilla" => 50,
    "beans" => 100,
    "cheese" => 150,
    "tofu" => 260,
    "rice_noodles" => 180,
    "peanuts" => 140,
    "salmon" => 620,
    "potato" => 55,
    "onion" => 30,
    "spinach" => 130
  }

  # {id, name, slot, [{ingredient, units}], allergens, {calories, protein_g, carbs_g, fat_g}}
  @recipes [
    {"b_oats", "Oatmeal with banana", "breakfast", [{"oats", 2}, {"milk", 2}, {"banana", 2}],
     ["milk"], {420, 14, 70, 9}},
    {"b_eggs", "Scrambled eggs on toast", "breakfast", [{"eggs", 6}, {"bread", 4}],
     ["egg", "gluten"], {380, 24, 30, 18}},
    {"b_pb_toast", "Peanut butter toast", "breakfast",
     [{"bread", 4}, {"peanut_butter", 2}, {"banana", 1}], ["peanut", "gluten"],
     {450, 15, 52, 20}},
    {"b_yogurt", "Yogurt bowl", "breakfast", [{"yogurt", 3}, {"banana", 1}, {"oats", 1}],
     ["milk"], {350, 18, 48, 8}},
    {"l_lentil_stew", "Lentil stew", "lunch",
     [{"lentils", 3}, {"tomato", 2}, {"onion", 1}, {"rice", 2}], [], {520, 28, 85, 6}},
    {"l_chicken_rice", "Chicken with rice", "lunch", [{"chicken", 2}, {"rice", 3}, {"onion", 1}],
     [], {610, 45, 70, 14}},
    {"l_tomato_pasta", "Tomato pasta", "lunch", [{"pasta", 4}, {"tomato", 3}, {"cheese", 1}],
     ["gluten", "milk"], {640, 22, 98, 16}},
    {"l_bean_tacos", "Bean tacos", "lunch",
     [{"tortilla", 6}, {"beans", 3}, {"cheese", 1}, {"tomato", 1}], ["gluten", "milk"],
     {590, 24, 80, 18}},
    {"d_pad_thai", "Peanut pad thai", "dinner",
     [{"rice_noodles", 3}, {"peanuts", 2}, {"tofu", 1}, {"eggs", 2}], ["peanut", "egg", "soy"],
     {680, 26, 88, 24}},
    {"d_salmon", "Salmon with potatoes", "dinner", [{"salmon", 2}, {"potato", 4}, {"spinach", 1}],
     ["fish"], {620, 42, 45, 28}},
    {"d_beef_stew", "Beef stew", "dinner",
     [{"beef", 2}, {"potato", 3}, {"onion", 2}, {"tomato", 2}], [], {650, 44, 40, 30}},
    {"d_tofu_stir_fry", "Tofu stir-fry", "dinner",
     [{"tofu", 2}, {"rice", 3}, {"spinach", 1}, {"onion", 1}], ["soy"], {540, 27, 72, 15}},
    {"d_spinach_omelette", "Spinach omelette", "dinner",
     [{"eggs", 6}, {"spinach", 1}, {"potato", 2}, {"cheese", 1}], ["egg", "milk"],
     {480, 30, 25, 28}}
  ]

  @households [
    %{
      id: "aurora",
      name: "Casa Aurora",
      members: [
        %{name: "Ana", allergies: []},
        %{name: "Luis", allergies: []}
      ],
      weekly_budget_cents: 16_000,
      inventory: ["rice", "eggs", "onion"],
      macro_bounds: %{
        "calories" => %{"min" => 1700, "max" => 2400},
        "protein_g" => %{"min" => 70, "max" => 160},
        "carbs_g" => %{"min" => 150, "max" => 320},
        "fat_g" => %{"min" => 40, "max" => 90}
      }
    },
    %{
      id: "boreal",
      name: "Casa Boreal",
      members: [
        %{name: "Carla", allergies: []},
        %{name: "Bruno", allergies: ["peanut"]},
        %{name: "Dani", allergies: []}
      ],
      weekly_budget_cents: 17_000,
      inventory: ["oats", "lentils", "tomato"],
      macro_bounds: %{
        "calories" => %{"min" => 1550, "max" => 2400},
        "protein_g" => %{"min" => 60, "max" => 160},
        "carbs_g" => %{"min" => 140, "max" => 320},
        "fat_g" => %{"min" => 35, "max" => 90}
      }
    }
  ]

  def days, do: @days
  def slots, do: @slots
  def households, do: @households
  def household(id), do: Enum.find(@households, &(&1.id == id))
  def prices, do: @prices

  def recipes do
    Enum.map(@recipes, fn {id, name, slot, ingredients, allergens, {kcal, protein, carbs, fat}} ->
      %{
        id: id,
        name: name,
        slot: slot,
        ingredients:
          Enum.map(ingredients, fn {ingredient, units} -> %{id: ingredient, units: units} end),
        allergens: allergens,
        calories: kcal,
        protein_g: protein,
        carbs_g: carbs,
        fat_g: fat,
        cost_cents:
          Enum.sum(
            Enum.map(ingredients, fn {ingredient, units} ->
              units * Map.fetch!(@prices, ingredient)
            end)
          )
      }
    end)
  end

  def recipe(id), do: Enum.find(recipes(), &(&1.id == id))

  @doc "Allergens of the recipe that hit a member, as `[%{member, allergen}]`."
  def allergen_conflicts(household, recipe) do
    for member <- household.members,
        allergen <- member.allergies,
        allergen in recipe.allergens,
        do: %{member: member.name, allergen: allergen}
  end

  def inventory_hits(household, recipe) do
    Enum.count(recipe.ingredients, &(&1.id in household.inventory))
  end
end
