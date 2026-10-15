defmodule MealPlannerApi.Optimization.Variety do
  @moduledoc """
  Variety part of an optimizer request (spec #93, issue #98; see
  `docs/OPTIMIZER_CONTRACT.md`).

  The optimizer enforces two hard rules that never relax:

    * a recipe appears at most `variety_cap` times (default 2) in any rolling
      7-day window, counted across every slot;
    * a recipe never fills the same slot on two consecutive days.

  Both rules also look back: the confirmed Planned Meals of the 6 days before
  the Planning Range are passed by code, never by the agent, as fixed
  `prior_meals` context, so a new range does not repeat what was just eaten.
  The cap belongs to the Planning Session and is adjustable there.
  """

  import Ecto.Query

  alias MealPlannerApi.Persistence.Planning.ScheduledMeal
  alias MealPlannerApi.Repo

  @default_cap 2
  @prior_days 6
  @slot_order %{breakfast: 0, lunch: 1, snack: 2, dinner: 3}

  @type prior_meal :: %{required(String.t()) => String.t()}

  @doc "The variety cap a Planning Session starts with."
  @spec default_cap() :: pos_integer()
  def default_cap, do: @default_cap

  @doc """
  The Household's confirmed Planned Meals of the 6 days before `range_from`,
  as optimizer `prior_meals` entries ordered by day and slot. Meals without a
  recipe are skipped.
  """
  @spec prior_meals(Ecto.UUID.t(), Date.t()) :: [prior_meal()]
  def prior_meals(account_id, %Date{} = range_from) do
    from_date = Date.add(range_from, -@prior_days)
    to_date = Date.add(range_from, -1)

    from(m in ScheduledMeal,
      where:
        m.account_id == ^account_id and m.date >= ^from_date and m.date <= ^to_date and
          not is_nil(m.recipe_id),
      select: {m.date, m.slot, m.recipe_id}
    )
    |> Repo.all()
    |> Enum.sort_by(fn {date, slot, _recipe_id} ->
      {Date.to_iso8601(date), Map.fetch!(@slot_order, slot)}
    end)
    |> Enum.map(fn {date, slot, recipe_id} ->
      %{"day" => Date.to_iso8601(date), "slot" => Atom.to_string(slot), "recipe_id" => recipe_id}
    end)
  end

  @doc """
  Adds the prior context and the Planning Session's variety cap to an
  optimizer payload.
  """
  @spec put(map(), [prior_meal()], term()) :: {:ok, map()} | {:error, :invalid_variety_cap}
  def put(payload, prior_meals, cap \\ @default_cap)

  def put(%{} = payload, prior_meals, cap)
      when is_list(prior_meals) and is_integer(cap) and cap > 0 do
    constraints =
      payload
      |> Map.get("constraints", %{})
      |> Map.put("variety_cap", cap)

    {:ok, Map.merge(payload, %{"constraints" => constraints, "prior_meals" => prior_meals})}
  end

  def put(_payload, _prior_meals, _cap), do: {:error, :invalid_variety_cap}
end
