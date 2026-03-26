alias MealPlannerApi.Persistence.Accounts
alias MealPlannerApi.Persistence.Catalog
alias MealPlannerApi.Persistence.Planning
alias MealPlannerApi.Repo
alias MealPlannerApi.Subscriptions.Plan

plans = [
  %{name: "individual", max_users: 1, max_planning_days: 7, revenuecat_entitlement_id: nil},
  %{name: "family_4", max_users: 4, max_planning_days: 7, revenuecat_entitlement_id: nil},
  %{name: "family_6", max_users: 6, max_planning_days: 7, revenuecat_entitlement_id: nil}
]

Enum.each(plans, fn attrs ->
  %Plan{}
  |> Plan.changeset(attrs)
  |> Repo.insert(
    on_conflict:
      {:replace, [:max_users, :max_planning_days, :revenuecat_entitlement_id, :updated_at]},
    conflict_target: [:name]
  )
end)

family_4_plan = Repo.get_by!(Plan, name: "family_4")

{:ok, account} =
  Accounts.create_account(%{
    name: "Familia Demo",
    account_type: :group,
    default_budget_cents: 95_000,
    subscription_plan_id: family_4_plan.id
  })

{:ok, owner} =
  Accounts.create_user(%{
    account_id: account.id,
    email: "owner@myfood.local",
    name: "Owner Demo",
    role: :owner
  })

{:ok, _member} =
  Accounts.create_user(%{
    account_id: account.id,
    email: "member@myfood.local",
    name: "Member Demo",
    role: :member
  })

{:ok, _diet} =
  Accounts.upsert_user_dietary_profile(owner.id, %{
    diet_type: :omnivore,
    macro_goal: :balanced
  })

{:ok, tomato} =
  Catalog.upsert_ingredient_by_name(%{
    name: "Tomate",
    category: :verduras,
    calories_per_100: 18,
    protein_g_per_100: Decimal.new("0.9"),
    carbs_g_per_100: Decimal.new("3.9"),
    fat_g_per_100: Decimal.new("0.2")
  })

{:ok, rice} =
  Catalog.upsert_ingredient_by_name(%{
    name: "Arroz",
    category: :granos,
    calories_per_100: 130,
    protein_g_per_100: Decimal.new("2.7"),
    carbs_g_per_100: Decimal.new("28.0"),
    fat_g_per_100: Decimal.new("0.3")
  })

{:ok, recipe} =
  Catalog.create_recipe(%{
    account_id: account.id,
    created_by_user_id: owner.id,
    name: "Arroz con tomate",
    source: :user_created,
    servings: 2,
    suitable_for_slots: [:lunch, :dinner]
  })

{:ok, _step} =
  Catalog.add_recipe_step(%{
    recipe_id: recipe.id,
    step_number: 1,
    instructions: "Cocinar arroz y mezclar con tomate."
  })

{:ok, _ri1} =
  Catalog.add_recipe_ingredient(%{
    recipe_id: recipe.id,
    ingredient_id: rice.id,
    quantity_milli: 300,
    unit: :g
  })

{:ok, _ri2} =
  Catalog.add_recipe_ingredient(%{
    recipe_id: recipe.id,
    ingredient_id: tomato.id,
    quantity_milli: 200,
    unit: :g
  })

{:ok, _meal} =
  Planning.schedule_meal(%{
    account_id: account.id,
    date: Date.utc_today(),
    slot: :lunch,
    recipe_id: recipe.id,
    is_cooked: false
  })

IO.puts("Seed data inserted successfully.")
