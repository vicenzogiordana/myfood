defmodule MealPlannerApi.PlanningAgent.Confirmation do
  @moduledoc """
  Saving a confirmed Proposal (spec #93, issue #102). Only the Member's
  confirmation reaches this module; no agent tool does.

  One transaction:

    1. the Planning Session moves from `active` to `committed` (row-locked,
       so a cancelled or expired session cannot be confirmed)
    2. the confirmation row is inserted; its id is the confirmation
       identity (the Proposal id), so the same confirmation never saves twice
    3. the Recipe Drafts the Proposal uses are saved as private AI-created
       Household Recipes, keeping their ids (never as Catalog Recipes)
    4. the Proposal's Planned Meals are saved with their diners, guests and
       the batches of their recipe (`selected_quantity`)
    5. each Purchase line is appended to the Shopping List as a new pending
       line, attributed to the earliest Planned Meal needing its ingredient.
       Existing lines, pending and in-cart included, are never touched.

  ## Outcomes

  `run/3` returns `{:ok, summary}` once the confirmation is verifiably
  saved (a replay returns the original summary), `{:error, reason}` when the
  store definitively refused it (nothing saved), or `{:error, :unresolved}`
  when the outcome cannot be verified: a lost acknowledgement is reconciled
  by querying the status for up to `reconcile_window_ms/0` (30 s), and is
  never reported as a failure because the save might have happened. The
  status stays queryable with `status/3`.

  ## Store

  The store is `{module, opts}` implementing `commit/2` and `status/3`; this
  module is the default store. A store call that raises or exits has an
  unknown outcome.
  """

  import Ecto.Query

  alias MealPlannerApi.Data.PlanningRepo
  alias MealPlannerApi.Persistence.Catalog.RecipeIngredient
  alias MealPlannerApi.Persistence.Planning.{AgentConfirmation, ScheduledMeal}
  alias MealPlannerApi.Persistence.Shopping.ShoppingItem
  alias MealPlannerApi.PlanningAgent.RecipeDraft
  alias MealPlannerApi.Repo

  @reconcile_window_ms 30_000
  @poll_interval_ms 1_000
  @slot_order ~w(breakfast lunch snack dinner)

  @type summary :: %{
          confirmation_id: Ecto.UUID.t(),
          meals_count: non_neg_integer(),
          shopping_lines_count: non_neg_integer()
        }

  @type attrs :: %{
          confirmation_id: Ecto.UUID.t(),
          account_id: Ecto.UUID.t(),
          session_id: Ecto.UUID.t(),
          membership_id: Ecto.UUID.t(),
          user_id: Ecto.UUID.t() | nil,
          range: {Date.t(), Date.t()},
          meals: [
            %{
              required(:date) => Date.t(),
              required(:slot) => String.t(),
              required(:recipe_id) => Ecto.UUID.t(),
              optional(:diners) => non_neg_integer(),
              optional(:guests) => non_neg_integer(),
              optional(:batches) => pos_integer()
            }
          ],
          recipes: [RecipeDraft.t()],
          purchase: MealPlannerApi.PlanningAgent.Purchase.t()
        }

  @type store :: {module(), keyword()}

  @callback commit(attrs(), keyword()) :: {:ok, summary()} | {:error, term()}
  @callback status(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
              {:confirmed, summary()} | :not_found

  @doc "How long a lost acknowledgement is reconciled before it is unresolved."
  @spec reconcile_window_ms() :: pos_integer()
  def reconcile_window_ms, do: @reconcile_window_ms

  @doc "The default store."
  @spec store() :: store()
  def store, do: {__MODULE__, []}

  @doc """
  Saves the confirmation `attrs` through `store`, idempotently.

  Options: `:reconcile_ms` (default `reconcile_window_ms/0`) and
  `:poll_ms` (default 1 s), the interval between status queries.
  """
  @spec run(store(), attrs(), keyword()) ::
          {:ok, summary()} | {:error, :unresolved | term()}
  def run(store, attrs, opts \\ []) do
    deadline =
      System.monotonic_time(:millisecond) + Keyword.get(opts, :reconcile_ms, @reconcile_window_ms)

    poll_ms = Keyword.get(opts, :poll_ms, @poll_interval_ms)
    reconcile = fn -> reconcile(store, attrs, deadline, poll_ms) end

    case lookup(store, attrs.account_id, attrs.confirmation_id) do
      {:confirmed, summary} ->
        {:ok, summary}

      :unknown ->
        reconcile.()

      :not_found ->
        case safe(fn -> call(store, :commit, [attrs]) end) do
          {:ok, {:ok, summary}} ->
            {:ok, summary}

          # A refusal may be a concurrent replay that already saved it.
          {:ok, {:error, reason}} ->
            case lookup(store, attrs.account_id, attrs.confirmation_id) do
              {:confirmed, summary} -> {:ok, summary}
              :not_found -> {:error, reason}
              :unknown -> reconcile.()
            end

          :unknown ->
            reconcile.()
        end
    end
  end

  @doc """
  The status of the confirmation `confirmation_id` in the Household:
  `{:confirmed, summary}`, `:not_found`, or `:unknown` when it cannot be
  read right now.
  """
  @spec lookup(store(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:confirmed, summary()} | :not_found | :unknown
  def lookup(store, account_id, confirmation_id) do
    case safe(fn -> call(store, :status, [account_id, confirmation_id]) end) do
      {:ok, {:confirmed, _summary} = confirmed} -> confirmed
      {:ok, :not_found} -> :not_found
      _ -> :unknown
    end
  end

  # ---------------------------------------------------------------------------
  # Default store
  # ---------------------------------------------------------------------------

  @doc "Commits the confirmation in one transaction."
  @spec commit(attrs(), keyword()) :: {:ok, summary()} | {:error, term()}
  def commit(attrs, _opts \\ []) do
    {from_date, to_date} = attrs.range

    Ecto.Multi.new()
    |> PlanningRepo.mark_committed(attrs.account_id, attrs.session_id)
    |> Ecto.Multi.run(:confirmation, fn repo, _ ->
      %AgentConfirmation{}
      |> AgentConfirmation.changeset(%{
        id: attrs.confirmation_id,
        account_id: attrs.account_id,
        planning_session_id: attrs.session_id,
        confirmed_by_membership_id: attrs.membership_id,
        range_from: from_date,
        range_to: to_date,
        meals_count: length(attrs.meals),
        shopping_lines_count: length(attrs.purchase.lines)
      })
      |> repo.insert()
      |> refusal(:already_confirmed)
    end)
    |> Ecto.Multi.run(:recipes, fn repo, _ -> insert_recipes(repo, attrs) end)
    |> Ecto.Multi.run(:planned_meals, fn repo, _ -> insert_meals(repo, attrs) end)
    |> Ecto.Multi.run(:shopping_lines, fn repo, %{planned_meals: meals} ->
      append_lines(repo, attrs, meals)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{confirmation: confirmation}} -> {:ok, summary(confirmation)}
      {:error, :mark_committed, :session_lock_lost, _} -> {:error, :session_not_active}
      {:error, _step, reason, _} when is_atom(reason) -> {:error, reason}
      {:error, _step, _reason, _} -> {:error, :rejected}
    end
  rescue
    # The database answered with an error: the transaction was rolled back.
    # Connection errors are not rescued: their outcome is unknown.
    _error in Postgrex.Error -> {:error, :rejected}
  end

  @doc "Reads a confirmation of the Household."
  @spec status(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) :: {:confirmed, summary()} | :not_found
  def status(account_id, confirmation_id, _opts \\ []) do
    with {:ok, id} <- Ecto.UUID.cast(confirmation_id),
         %AgentConfirmation{} = row <-
           Repo.one(
             from(c in AgentConfirmation, where: c.id == ^id and c.account_id == ^account_id)
           ) do
      {:confirmed, summary(row)}
    else
      _ -> :not_found
    end
  end

  # ---------------------------------------------------------------------------

  defp reconcile(store, attrs, deadline, poll_ms) do
    case lookup(store, attrs.account_id, attrs.confirmation_id) do
      {:confirmed, summary} ->
        {:ok, summary}

      _not_verified ->
        remaining = deadline - System.monotonic_time(:millisecond)

        if remaining <= 0 do
          {:error, :unresolved}
        else
          Process.sleep(min(poll_ms, remaining))
          reconcile(store, attrs, deadline, poll_ms)
        end
    end
  end

  defp insert_recipes(repo, attrs) do
    attrs
    |> Map.get(:recipes, [])
    |> Enum.filter(&RecipeDraft.plannable?/1)
    |> Enum.reduce_while({:ok, 0}, fn draft, {:ok, count} ->
      case RecipeDraft.persist(repo, draft, attrs.account_id, Map.get(attrs, :user_id)) do
        {:ok, _recipe} -> {:cont, {:ok, count + 1}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp insert_meals(repo, attrs) do
    Enum.reduce_while(attrs.meals, {:ok, []}, fn meal, {:ok, acc} ->
      %ScheduledMeal{}
      |> ScheduledMeal.changeset(%{
        account_id: attrs.account_id,
        date: meal.date,
        slot: meal.slot,
        recipe_id: meal.recipe_id,
        is_cooked: false,
        # The batches its diners need: the Projected Pantry commits them.
        selected_quantity: Map.get(meal, :batches, 1),
        diners: Map.get(meal, :diners),
        guests: Map.get(meal, :guests, 0)
      })
      |> repo.insert()
      |> case do
        {:ok, saved} -> {:cont, {:ok, [saved | acc]}}
        {:error, _changeset} -> {:halt, {:error, :range_already_planned}}
      end
    end)
    |> case do
      {:ok, saved} -> {:ok, Enum.reverse(saved)}
      error -> error
    end
  end

  # Appends one pending line per Purchase line. A line is attributed to the
  # earliest Planned Meal whose recipe needs its ingredient in its unit.
  defp append_lines(repo, attrs, meals) do
    first_meal = first_meal_by_need(repo, meals)

    Enum.reduce_while(attrs.purchase.lines, {:ok, 0}, fn line, {:ok, count} ->
      meal = Map.fetch!(first_meal, {line.ingredient_id, line.unit})

      %ShoppingItem{}
      |> ShoppingItem.changeset(%{
        account_id: attrs.account_id,
        scheduled_meal_id: meal.id,
        planned_date: meal.date,
        ingredient_id: line.ingredient_id,
        quantity_milli: line.quantity_milli,
        unit: line.unit,
        status: :pending,
        estimated_price_cents: line.total_cents
      })
      |> repo.insert()
      |> case do
        {:ok, _item} -> {:cont, {:ok, count + 1}}
        {:error, _changeset} -> {:halt, {:error, :invalid_shopping_line}}
      end
    end)
  end

  defp first_meal_by_need(repo, meals) do
    recipe_ids = meals |> Enum.map(& &1.recipe_id) |> Enum.uniq()

    needs =
      from(ri in RecipeIngredient,
        where: ri.recipe_id in ^recipe_ids,
        select: {ri.recipe_id, ri.ingredient_id, ri.unit}
      )
      |> repo.all()
      |> Enum.group_by(&elem(&1, 0), fn {_, ingredient_id, unit} -> {ingredient_id, unit} end)

    meals
    |> Enum.sort_by(&{Date.to_gregorian_days(&1.date), slot_rank(&1.slot)}, :desc)
    |> Enum.reduce(%{}, fn meal, acc ->
      needs
      |> Map.get(meal.recipe_id, [])
      |> Enum.reduce(acc, &Map.put(&2, &1, meal))
    end)
  end

  defp slot_rank(slot),
    do: Enum.find_index(@slot_order, &(&1 == to_string(slot))) || length(@slot_order)

  defp refusal({:ok, _} = ok, _reason), do: ok
  defp refusal({:error, _changeset}, reason), do: {:error, reason}

  defp summary(%AgentConfirmation{} = row) do
    %{
      confirmation_id: row.id,
      meals_count: row.meals_count,
      shopping_lines_count: row.shopping_lines_count
    }
  end

  defp call({module, opts}, :commit, [attrs]), do: module.commit(attrs, opts)

  defp call({module, opts}, :status, [account_id, id]),
    do: module.status(account_id, id, opts)

  defp safe(fun) do
    {:ok, fun.()}
  rescue
    _error -> :unknown
  catch
    :exit, _reason -> :unknown
  end
end
