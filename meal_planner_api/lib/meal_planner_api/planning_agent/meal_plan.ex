defmodule MealPlannerApi.PlanningAgent.MealPlan do
  @moduledoc """
  Read-only view of a Household's Meal Plan for the planning agent (spec #93,
  #105): the confirmed Planned Meals of a date range, and their reuse as a
  draft for a new Planning Range. It reports what was planned, never whether
  a meal was eaten.

  Every read is scoped to the given Household, which callers take from the
  Planning Session, never from model arguments.
  """

  import Ecto.Query

  alias MealPlannerApi.Persistence.Catalog.Recipe
  alias MealPlannerApi.Persistence.Planning.ScheduledMeal
  alias MealPlannerApi.Repo

  # Bounds one lookup to about a quarter so a tool result stays small.
  @max_range_days 92
  @slot_order %{"breakfast" => 0, "lunch" => 1, "snack" => 2, "dinner" => 3}

  @type planned_meal :: %{
          date: Date.t(),
          slot: String.t(),
          recipe_id: Ecto.UUID.t() | nil,
          name: String.t() | nil
        }

  @doc "The largest range, in days, one lookup accepts."
  @spec max_range_days() :: pos_integer()
  def max_range_days, do: @max_range_days

  @doc """
  Parses an ISO `from` date and an optional ISO `to` date (defaulting to
  `from`) into an inclusive range of at most `max_range_days/0` days.
  """
  @spec parse_range(term(), term()) :: {:ok, {Date.t(), Date.t()}} | {:error, :invalid_range}
  def parse_range(from, to \\ nil)

  def parse_range(from, nil) when is_binary(from), do: parse_range(from, from)

  def parse_range(from, to) when is_binary(from) and is_binary(to) do
    with {:ok, from_date} <- Date.from_iso8601(from),
         {:ok, to_date} <- Date.from_iso8601(to),
         days = Date.diff(to_date, from_date) + 1,
         true <- days >= 1 and days <= @max_range_days do
      {:ok, {from_date, to_date}}
    else
      _ -> {:error, :invalid_range}
    end
  end

  def parse_range(_from, _to), do: {:error, :invalid_range}

  @doc "Planned Meals of the Household in the inclusive range, by date and slot."
  @spec list(Ecto.UUID.t(), {Date.t(), Date.t()}) :: [planned_meal()]
  def list(account_id, {%Date{} = from_date, %Date{} = to_date}) do
    from(m in ScheduledMeal,
      left_join: r in Recipe,
      on: r.id == m.recipe_id,
      where: m.account_id == ^account_id and m.date >= ^from_date and m.date <= ^to_date,
      select: %{
        date: m.date,
        slot: m.slot,
        recipe_id: m.recipe_id,
        name: r.name,
        snapshot: m.recipe_snapshot
      }
    )
    |> Repo.all()
    |> Enum.map(fn row ->
      %{
        date: row.date,
        slot: Atom.to_string(row.slot),
        recipe_id: row.recipe_id,
        name: row.name || snapshot_name(row.snapshot)
      }
    end)
    |> Enum.sort_by(&{Date.to_gregorian_days(&1.date), Map.fetch!(@slot_order, &1.slot)})
  end

  @doc """
  Maps the Planned Meals of a past window onto the Planning Range for reuse
  ("repeat the week before last").

  The window starts at the ISO date `source_from`, spans as many days as the
  Planning Range and must end before it starts. Each meal moves by the same
  day offset; only the session's `slots` are kept, as are only meals whose
  recipe still exists. The result carries day, slot and recipe only: portions,
  recipe versions, Deviation Approvals and Absence Exceptions of the past plan
  are never inherited, so the draft must pass full validation again.
  """
  @spec reuse(Ecto.UUID.t(), term(), {Date.t(), Date.t()}, [String.t()]) ::
          {:ok, [planned_meal()]} | {:error, :invalid_source | :no_planned_meals}
  def reuse(account_id, source_from, {range_from, range_to}, slots) do
    with {:ok, source_date} <- parse_source(source_from),
         source_to = Date.add(source_date, Date.diff(range_to, range_from)),
         :ok <- ensure_before(source_to, range_from) do
      offset = Date.diff(range_from, source_date)

      account_id
      |> list({source_date, source_to})
      |> Enum.filter(&(&1.slot in slots and is_binary(&1.recipe_id)))
      |> Enum.map(&%{&1 | date: Date.add(&1.date, offset)})
      |> case do
        [] -> {:error, :no_planned_meals}
        meals -> {:ok, meals}
      end
    end
  end

  defp parse_source(source_from) when is_binary(source_from) do
    case Date.from_iso8601(source_from) do
      {:ok, date} -> {:ok, date}
      {:error, _} -> {:error, :invalid_source}
    end
  end

  defp parse_source(_source_from), do: {:error, :invalid_source}

  defp ensure_before(source_to, range_from) do
    if Date.compare(source_to, range_from) == :lt, do: :ok, else: {:error, :invalid_source}
  end

  defp snapshot_name(%{"name" => name}) when is_binary(name), do: name
  defp snapshot_name(_snapshot), do: nil
end
