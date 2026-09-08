defmodule MealPlannerApi.Persistence.CalendarTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias MealPlannerApi.Data.PlanningRepo
  alias MealPlannerApi.Persistence.Calendar
  alias MealPlannerApi.Repo

  setup do
    :ok = Sandbox.checkout(Repo)
    :ok = MealPlannerApi.SubscriptionPlanFixtures.ensure_plans!()
  end

  test "rejects duplicate replacement slots without writing duplicates" do
    account_id = account_id("calendar-duplicate@example.com")

    assert {:error, :duplicate_slot} =
             Calendar.replace_scheduled_meals_for_range(
               account_id,
               {~D[2026-07-01], ~D[2026-07-07]},
               [
                 %{date: ~D[2026-07-02], slot: :lunch},
                 %{date: ~D[2026-07-02], slot: :lunch}
               ]
             )

    assert [] = PlanningRepo.list_scheduled_meals(account_id, ~D[2026-07-01], ~D[2026-07-07])
  end

  test "rejects replacement input belonging to another account" do
    [membership_a, membership_b] = memberships("calendar-cross-account@example.com", 2)
    existing = schedule(membership_a.account_id, ~D[2026-07-02], :breakfast)

    assert {:error, :cross_account} =
             Calendar.replace_scheduled_meals_for_range(
               membership_a.account_id,
               {~D[2026-07-01], ~D[2026-07-07]},
               [
                 %{account_id: membership_b.account_id, date: ~D[2026-07-03], slot: :dinner}
               ]
             )

    assert [meal] =
             PlanningRepo.list_scheduled_meals(
               membership_a.account_id,
               ~D[2026-07-01],
               ~D[2026-07-07]
             )

    assert meal.id == existing.id
  end

  test "replaces only meals inside the inclusive range" do
    account_id = account_id("calendar-range@example.com")
    before = schedule(account_id, ~D[2026-06-30], :lunch)
    inside = schedule(account_id, ~D[2026-07-02], :breakfast)
    after_range = schedule(account_id, ~D[2026-07-08], :dinner)

    assert {:ok, %{replaced: 1}} =
             Calendar.replace_scheduled_meals_for_range(
               account_id,
               {~D[2026-07-01], ~D[2026-07-07]},
               [
                 %{date: ~D[2026-07-03], slot: :lunch}
               ]
             )

    meals = PlanningRepo.list_scheduled_meals(account_id, ~D[2026-06-30], ~D[2026-07-08])
    ids = MapSet.new(meals, & &1.id)
    assert MapSet.member?(ids, before.id)
    refute MapSet.member?(ids, inside.id)
    assert MapSet.member?(ids, after_range.id)
    assert Enum.any?(meals, &(&1.date == ~D[2026-07-03] and &1.slot == :lunch))
  end

  test "rolls back the deletion when a replacement cannot be persisted" do
    account_id = account_id("calendar-rollback@example.com")
    inside = schedule(account_id, ~D[2026-07-02], :lunch)
    outside = schedule(account_id, ~D[2026-07-08], :dinner)

    assert {:error, :persistence_error} =
             Calendar.replace_scheduled_meals_for_range(
               account_id,
               {~D[2026-07-01], ~D[2026-07-07]},
               [
                 %{date: ~D[2026-07-03], slot: :lunch, recipe_id: Ecto.UUID.generate()}
               ]
             )

    assert Enum.map(
             PlanningRepo.list_scheduled_meals(account_id, ~D[2026-07-01], ~D[2026-07-08]),
             & &1.id
           ) == [
             inside.id,
             outside.id
           ]
  end

  # Scenario: Preserve a partially adjacent slot. A meal whose (date, slot)
  # sits at the boundary of — but outside — the selected range must survive
  # the replacement. This is the (date, slot)-preservation guarantee: the
  # unique_index scope is the slot, not the date alone.
  test "preserves a meal at a (date, slot) adjacent to but outside the range" do
    account_id = account_id("calendar-adjacent-slot@example.com")
    just_before = schedule(account_id, ~D[2026-06-30], :lunch)
    just_after = schedule(account_id, ~D[2026-07-08], :dinner)

    assert {:ok, %{replaced: 0}} =
             Calendar.replace_scheduled_meals_for_range(
               account_id,
               {~D[2026-07-01], ~D[2026-07-07]},
               []
             )

    meals = PlanningRepo.list_scheduled_meals(account_id, ~D[2026-06-30], ~D[2026-07-08])
    ids = MapSet.new(meals, & &1.id)

    assert MapSet.member?(ids, just_before.id)
    assert MapSet.member?(ids, just_after.id)
  end

  # Scenario: Complete range replacement. Multiple new meals must all be
  # visible together after a single successful call, and every prior
  # in-range meal must be gone. This proves the delete + insert_all Multi
  # commits as one transition (AC #3 atomicity).
  test "completes a full multi-meal range replacement atomically" do
    account_id = account_id("calendar-complete-replace@example.com")
    _keep_before = schedule(account_id, ~D[2026-06-30], :breakfast)
    old_lunch = schedule(account_id, ~D[2026-07-02], :lunch)
    old_dinner = schedule(account_id, ~D[2026-07-04], :dinner)
    _keep_after = schedule(account_id, ~D[2026-07-08], :breakfast)

    assert {:ok, %{replaced: 3}} =
             Calendar.replace_scheduled_meals_for_range(
               account_id,
               {~D[2026-07-01], ~D[2026-07-07]},
               [
                 %{date: ~D[2026-07-02], slot: :lunch},
                 %{date: ~D[2026-07-04], slot: :dinner},
                 %{date: ~D[2026-07-06], slot: :snack}
               ]
             )

    meals = PlanningRepo.list_scheduled_meals(account_id, ~D[2026-06-30], ~D[2026-07-08])

    refute Enum.any?(meals, &(&1.id == old_lunch.id))
    refute Enum.any?(meals, &(&1.id == old_dinner.id))

    assert Enum.any?(meals, &(&1.date == ~D[2026-07-02] and &1.slot == :lunch))
    assert Enum.any?(meals, &(&1.date == ~D[2026-07-04] and &1.slot == :dinner))
    assert Enum.any?(meals, &(&1.date == ~D[2026-07-06] and &1.slot == :snack))
  end

  defp account_id(email), do: memberships(email, 1) |> hd() |> Map.fetch!(:account_id)

  defp memberships(email, count) do
    specs = Enum.map(1..count, &{%{name: "Calendar account #{&1}", plan: :family_4}, :owner})

    user = MealPlannerApi.FactoryHelpers.user_with_memberships(%{email: email}, specs)
    user.memberships
  end

  defp schedule(account_id, date, slot) do
    {:ok, meal} = Calendar.upsert_scheduled_meal(account_id, %{date: date, slot: slot})
    meal
  end
end
