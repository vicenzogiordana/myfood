defmodule MealPlannerApi.PlanningAgent.Chat.Household do
  @moduledoc """
  The fictitious Household of the planning chat (`mix planning_agent.chat`):
  three Members (one allergic to peanuts), a weekly grocery budget, a small
  Pantry and 18 recipes over a priced catalog with two pasta brands.

  The fixtures are built with the quality battery's builder
  (`MealPlannerApi.PlanningAgent.Battery.Kitchen`), so they follow the same
  rules: every name is invented, prices are observed on the battery clock
  (`MealPlannerApi.PlanningAgent.Battery.Tasks.now/0`) and are fresh for the
  Planning Range, Monday 2 to Sunday 8 November 2026.
  """

  import Ecto.Query, only: [from: 2]

  alias MealPlannerApi.Persistence.Accounts.{AccountMembership, User}
  alias MealPlannerApi.PlanningAgent.Battery.Kitchen
  alias MealPlannerApi.Repo

  @range {~D[2026-11-02], ~D[2026-11-08]}
  @slots ["lunch", "dinner"]
  @budget_cents 4_500_000
  # Kitchen's fixed Owner, so a seeded Household is found again.
  @owner_email "battery-owner@example.test"
  @observed_at ~U[2026-11-01 08:00:00.000000Z]

  @type t :: %{
          account_id: Ecto.UUID.t(),
          owner: %{user_id: Ecto.UUID.t(), membership_id: Ecto.UUID.t(), role: :owner},
          range: {Date.t(), Date.t()},
          slots: [String.t()]
        }

  @doc "The Planning Range the chat plans."
  @spec range() :: {Date.t(), Date.t()}
  def range, do: @range

  @doc """
  The fixture spec (see `Kitchen`). `overrides` replace top-level keys, such
  as `:budget_cents`.
  """
  @spec spec(keyword()) :: map()
  def spec(overrides \\ []) do
    Map.merge(
      %{
        range: @range,
        slots: @slots,
        budget_cents: @budget_cents,
        members: [
          %{key: :owner, diet: nil, allergies: []},
          %{key: :partner, diet: nil, allergies: []},
          %{key: :kid, diet: nil, allergies: [:peanut]}
        ],
        ingredients: ingredients(),
        products: products(),
        recipes: recipes(),
        pantry: [
          %{ingredient: :rice, quantity_milli: 1_000_000, unit: :g},
          %{ingredient: :onion, quantity_milli: 500_000, unit: :g},
          %{ingredient: :egg, quantity_milli: 6_000, unit: :unit}
        ],
        planned_meals: []
      },
      Map.new(overrides)
    )
  end

  @doc """
  The seeded Household, building it first when the database holds none.
  `overrides` reach `spec/1` only when the Household is built.
  """
  @spec ensure(keyword()) :: {:existing | :seeded, t()}
  def ensure(overrides \\ []) do
    case find() do
      nil -> {:seeded, seed(overrides)}
      household -> {:existing, household}
    end
  end

  @doc """
  Builds the Household of `spec(overrides)` in one transaction: a seed that
  is interrupted leaves nothing behind, so it is never found as an
  existing Household.
  """
  @spec seed(keyword()) :: t()
  def seed(overrides \\ []) do
    {:ok, household} =
      Repo.transaction(
        fn ->
          overrides
          |> spec()
          |> Kitchen.build()
          |> Map.take([:account_id, :owner, :range, :slots])
        end,
        timeout: :infinity
      )

    household
  end

  @doc """
  Empties every table of the database but the migrations, so the next
  `ensure/1` seeds again. Only for the chat's own database: it refuses
  (`Mix.Error`) any database whose name does not end in `_chat`.
  """
  @spec reset!() :: :ok
  def reset! do
    database = to_string(Repo.config()[:database])

    unless String.ends_with?(database, "_chat") do
      Mix.raise(
        "--reset only empties a database whose name ends in _chat, " <>
          "for example meal_planner_api_chat; refused #{database}"
      )
    end

    %{rows: rows} =
      Repo.query!(
        "SELECT tablename FROM pg_tables WHERE schemaname = 'public' " <>
          "AND tablename <> 'schema_migrations'"
      )

    tables = Enum.map_join(rows, ", ", fn [table] -> ~s("#{table}") end)
    if tables != "", do: Repo.query!("TRUNCATE #{tables} RESTART IDENTITY CASCADE")
    :ok
  end

  defp find do
    query =
      from(m in AccountMembership,
        join: u in User,
        on: u.id == m.user_id,
        where: u.email == ^@owner_email and m.role == :owner,
        select: %{account_id: m.account_id, user_id: u.id, membership_id: m.id},
        limit: 1
      )

    case Repo.one(query) do
      nil ->
        nil

      row ->
        %{
          account_id: row.account_id,
          owner: %{user_id: row.user_id, membership_id: row.membership_id, role: :owner},
          range: @range,
          slots: @slots
        }
    end
  end

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  defp ingredients do
    [
      %{key: :rice, name: "Arroz largo fino", tags: []},
      %{key: :spaghetti, name: "Fideos spaghetti", tags: [:contains_gluten]},
      %{key: :penne, name: "Fideos penne", tags: [:contains_gluten]},
      %{key: :tomato, name: "Tomate perita", tags: []},
      %{key: :lentils, name: "Lentejas", tags: []},
      %{key: :chickpeas, name: "Garbanzos", tags: []},
      %{key: :spinach, name: "Espinaca", tags: []},
      %{key: :potato, name: "Papa", tags: []},
      %{key: :onion, name: "Cebolla", tags: []},
      %{key: :squash, name: "Zapallo", tags: []},
      %{key: :chicken, name: "Pollo", tags: [:contains_meat]},
      %{key: :ground_beef, name: "Carne picada", tags: [:contains_meat]},
      %{key: :hake, name: "Merluza", tags: [:contains_fish]},
      %{key: :egg, name: "Huevo", tags: [:egg, :animal_product]},
      %{key: :cheese, name: "Queso cremoso", tags: [:milk, :animal_product]},
      %{key: :peanut, name: "Mani tostado", tags: [:peanut]},
      %{key: :flour, name: "Harina de trigo", tags: [:contains_gluten]},
      %{key: :yeast, name: "Levadura", tags: []},
      %{key: :mozzarella, name: "Muzzarella", tags: [:milk, :animal_product]},
      %{key: :bun, name: "Pan de hamburguesa", tags: [:contains_gluten]},
      %{key: :oil, name: "Aceite de oliva", tags: []}
    ]
  end

  defp products do
    [
      product(:rice, "Arroz largo fino 1 kg", "Campo Sur", {1_000_000, :g}, 120_000),
      product(:spaghetti, "Spaghetti Don Trigo 500 g", "Don Trigo", {500_000, :g}, 95_000),
      product(:spaghetti, "Spaghetti La Molienda 500 g", "La Molienda", {500_000, :g}, 140_000),
      product(:penne, "Penne Don Trigo 500 g", "Don Trigo", {500_000, :g}, 99_000),
      product(:penne, "Penne La Molienda 500 g", "La Molienda", {500_000, :g}, 150_000),
      product(:tomato, "Tomate perita 1 kg", nil, {1_000_000, :g}, 180_000),
      product(:lentils, "Lentejas 500 g", "Campo Sur", {500_000, :g}, 110_000),
      product(:chickpeas, "Garbanzos 500 g", "Campo Sur", {500_000, :g}, 130_000),
      product(:spinach, "Espinaca 500 g", nil, {500_000, :g}, 90_000),
      product(:potato, "Papa 2 kg", nil, {2_000_000, :g}, 160_000),
      product(:onion, "Cebolla 1 kg", nil, {1_000_000, :g}, 100_000),
      product(:squash, "Zapallo 1 kg", nil, {1_000_000, :g}, 85_000),
      product(:chicken, "Pechuga de pollo 1 kg", "Granja Norte", {1_000_000, :g}, 650_000),
      product(:ground_beef, "Carne picada 1 kg", nil, {1_000_000, :g}, 820_000),
      product(:hake, "Filet de merluza 1 kg", "Mar Austral", {1_000_000, :g}, 900_000),
      product(:egg, "Huevos x12", "Granja Norte", {12_000, :unit}, 280_000),
      product(:cheese, "Queso cremoso 500 g", "Tambo Azul", {500_000, :g}, 450_000),
      product(:peanut, "Mani tostado 250 g", "Campo Sur", {250_000, :g}, 210_000),
      product(:flour, "Harina de trigo 000 1 kg", "La Molienda", {1_000_000, :g}, 110_000),
      product(:yeast, "Levadura seca 10 g", nil, {10_000, :g}, 60_000),
      product(:mozzarella, "Muzzarella 1 kg", "Tambo Azul", {1_000_000, :g}, 780_000),
      product(:bun, "Pan de hamburguesa x4", "Panificados Sol", {4_000, :unit}, 210_000),
      product(:oil, "Aceite de oliva 500 ml", "Olivares del Sur", {500_000, :ml}, 650_000)
    ]
  end

  defp product(ingredient, name, brand, package, price_cents) do
    %{
      ingredient: ingredient,
      name: name,
      brand: brand,
      package: package,
      price_cents: price_cents,
      observed_at: @observed_at
    }
  end

  defp recipes do
    [
      recipe(:arroz_con_pollo, "Arroz con pollo", [:rice, :chicken, :onion]),
      recipe(:guiso_lentejas, "Guiso de lentejas", [:lentils, :potato, :onion, :tomato]),
      recipe(:spaghetti_fileto, "Spaghetti con salsa fileto", [:spaghetti, :tomato, :onion]),
      recipe(:spaghetti_bolognesa, "Spaghetti a la bolognesa", [:spaghetti, :ground_beef, :tomato]),
      recipe(:penne_espinaca, "Penne con espinaca y queso", [:penne, :spinach, :cheese]),
      recipe(:penne_pollo, "Penne con pollo", [:penne, :chicken, :onion]),
      recipe(:tortilla_papas, "Tortilla de papas", [:potato, {:egg, {3_000, :unit}}, :onion]),
      recipe(:merluza_pure, "Merluza con pure", [:hake, :potato]),
      recipe(:pastel_papa, "Pastel de papa", [:ground_beef, :potato, :onion]),
      recipe(:ensalada_garbanzos, "Ensalada de garbanzos", [:chickpeas, :tomato, :onion]),
      recipe(:zapallo_relleno, "Zapallo relleno", [:squash, :cheese, :onion]),
      recipe(:tarta_espinaca, "Tarta de espinaca", [:spinach, {:egg, {2_000, :unit}}, :cheese]),
      recipe(:pollo_al_horno, "Pollo al horno con papas", [:chicken, :potato]),
      recipe(:hamburguesas_lentejas, "Hamburguesas de lentejas", [
        :lentils,
        :onion,
        {:egg, {1_000, :unit}}
      ]),
      recipe(:arroz_primavera, "Arroz primavera", [:rice, :squash, :spinach]),
      recipe(:sopa_zapallo, "Sopa crema de zapallo", [:squash, :onion, :potato]),
      recipe(:pollo_mani, "Pollo salteado con mani", [:chicken, :peanut, :rice]),
      recipe(:fideos_mani, "Fideos con salsa de mani", [:spaghetti, :peanut, :onion])
    ]
  end

  defp recipe(key, name, ingredients), do: %{key: key, name: name, ingredients: ingredients}
end
