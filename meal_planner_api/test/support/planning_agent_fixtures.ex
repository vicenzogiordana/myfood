defmodule MealPlannerApi.PlanningAgentFixtures do
  @moduledoc """
  Fictitious households, members, ingredients and recipes for planning agent
  tests. Every name is invented; nothing mirrors real data.
  """

  alias MealPlannerApi.Persistence.Accounts.{
    AccountMembership,
    User,
    UserDietaryProfile,
    UserExcludedIngredient
  }

  alias MealPlannerApi.Persistence.Catalog
  alias MealPlannerApi.Persistence.Planning.ScheduledMeal
  alias MealPlannerApi.PlanningAgent.Consent
  alias MealPlannerApi.Repo

  import MealPlannerApi.FactoryHelpers, only: [user_with_memberships: 2]

  @doc """
  Checks out a shared sandbox owned by a separate process and, on exit, waits
  for every Planning Session to end (they stop once their subscriber, the test
  process, is gone) before the connection is released, so session processes
  never outlive the test's database access.
  """
  def sandbox_sessions! do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)

    ExUnit.Callbacks.on_exit(fn ->
      sup = MealPlannerApi.PlanningAgent.SessionSupervisor

      for {_, pid, _, _} <- DynamicSupervisor.which_children(sup), is_pid(pid) do
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, _, _, _} -> :ok
        after
          1_000 -> DynamicSupervisor.terminate_child(sup, pid)
        end
      end

      Ecto.Adapters.SQL.Sandbox.stop_owner(owner)
    end)

    :ok
  end

  @doc "A Household with its Owner. Returns `%{account_id, owner}`."
  def household!(name \\ "Fictitious Household") do
    owner =
      user_with_memberships(%{email: unique_email()}, [{%{plan: :family_4, name: name}, :owner}])

    [membership] = owner.memberships

    %{account_id: membership.account_id, owner: member_map(owner, membership)}
  end

  @doc "Adds an active Member to the Household."
  def member!(%{account_id: account_id}, role \\ :member) do
    user =
      %User{}
      |> User.changeset(%{email: unique_email(), name: "Fictitious Member", role: :member})
      |> Repo.insert!()

    membership =
      %AccountMembership{}
      |> AccountMembership.changeset(%{
        account_id: account_id,
        user_id: user.id,
        role: role,
        status: :active,
        joined_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    member_map(user, membership)
  end

  @doc "Session attributes for the given Member."
  def session_attrs(household, member, range, slots \\ ["lunch", "dinner"]) do
    %{
      account_id: household.account_id,
      user_id: member.user_id,
      membership_id: member.membership_id,
      role: member.role,
      range: range,
      slots: slots
    }
  end

  def consent!(household, member), do: :ok = Consent.record(household.account_id, member.user_id)

  def diet!(member, diet) do
    %UserDietaryProfile{}
    |> UserDietaryProfile.changeset(%{
      user_id: member.user_id,
      diet_type: diet,
      macro_goal: :balanced
    })
    |> Repo.insert!()
  end

  def allergy!(member, ingredient), do: exclusion!(member, ingredient, :allergy)
  def dislike!(member, ingredient), do: exclusion!(member, ingredient, :dislike)

  defp exclusion!(member, ingredient, reason) do
    %UserExcludedIngredient{}
    |> UserExcludedIngredient.changeset(%{
      user_id: member.user_id,
      ingredient_id: ingredient.id,
      reason: reason
    })
    |> Repo.insert!()
  end

  def ingredient!(name, tags \\ []) do
    {:ok, ingredient} =
      Catalog.create_ingredient(%{name: "#{name} #{unique()}", category: :otros})

    Enum.each(tags, fn tag -> {:ok, _} = Catalog.tag_ingredient(ingredient.id, tag) end)
    ingredient
  end

  def recipe!(name, ingredients, opts \\ []) do
    {:ok, recipe} =
      Catalog.create_recipe(%{
        name: name,
        servings: 2,
        suitable_for_slots: Keyword.get(opts, :slots, ["lunch", "dinner"]),
        source: :traditional,
        account_id: Keyword.get(opts, :account_id),
        calories_per_serving: 500
      })

    Enum.each(ingredients, fn ingredient ->
      {:ok, _} =
        Catalog.add_recipe_ingredient(%{
          recipe_id: recipe.id,
          ingredient_id: ingredient.id,
          quantity_milli: 100_000,
          unit: :g
        })
    end)

    recipe
  end

  def scheduled_meal!(household, date, slot, recipe) do
    %ScheduledMeal{}
    |> ScheduledMeal.changeset(%{
      account_id: household.account_id,
      date: date,
      slot: slot,
      recipe_id: recipe.id
    })
    |> Repo.insert!()
  end

  defp member_map(user, membership) do
    %{user_id: user.id, membership_id: membership.id, role: membership.role}
  end

  defp unique_email, do: "fictitious-#{unique()}@example.test"
  defp unique, do: System.unique_integer([:positive])
end
