defmodule MealPlannerApi.Data.PlanningRepo do
  @moduledoc """
  Pure data access for planning runs, proposals, meals, and cooking sessions.

  No business logic. No orchestration. Just queries and persistence.
  """

  import Ecto.Query, warn: false
  alias MealPlannerApi.Repo

  alias MealPlannerApi.Persistence.Accounts

  alias MealPlannerApi.Persistence.Catalog.{
    FavoriteRecipe,
    Recipe,
    RecipeDailyCost,
    RecipeIngredient,
    SlotFavorite
  }

  alias MealPlannerApi.Persistence.Planning.{
    ContextSnapshot,
    CookingChatMessage,
    CookingSession,
    CookingStepEvent,
    PlanningGenerationRun,
    PlanningProposal,
    ScheduledMeal
  }

  # -------------------------------------------------------------------------
  # Generation runs
  # -------------------------------------------------------------------------

  @spec create_generation_run(map()) ::
          {:ok, PlanningGenerationRun.t()} | {:error, Ecto.Changeset.t()}
  def create_generation_run(attrs),
    do: %PlanningGenerationRun{} |> PlanningGenerationRun.changeset(attrs) |> Repo.insert()

  @spec update_generation_run(PlanningGenerationRun.t(), map()) ::
          {:ok, PlanningGenerationRun.t()} | {:error, Ecto.Changeset.t()}
  def update_generation_run(run, attrs),
    do: run |> PlanningGenerationRun.changeset(attrs) |> Repo.update()

  # -------------------------------------------------------------------------
  # Proposals
  # -------------------------------------------------------------------------

  @spec create_proposal(map()) :: {:ok, PlanningProposal.t()} | {:error, Ecto.Changeset.t()}
  def create_proposal(attrs),
    do: %PlanningProposal{} |> PlanningProposal.changeset(attrs) |> Repo.insert()

  @spec update_proposal(PlanningProposal.t(), map()) ::
          {:ok, PlanningProposal.t()} | {:error, Ecto.Changeset.t()}
  def update_proposal(proposal, attrs),
    do: proposal |> PlanningProposal.changeset(attrs) |> Repo.update()

  @spec get_proposal_with_run!(pos_integer()) :: {PlanningProposal.t(), PlanningGenerationRun.t()}
  def get_proposal_with_run!(proposal_id) do
    query =
      from(p in PlanningProposal,
        join: r in assoc(p, :generation_run),
        where: p.id == ^proposal_id,
        preload: [generation_run: []]
      )

    proposal = Repo.one!(query)

    {:ok, run} =
      Repo.all(from(r in PlanningGenerationRun, where: r.id == ^proposal.generation_run_id))
      |> case do
        [run] -> {:ok, run}
        [] -> {:error, :not_found}
      end

    {proposal, run}
  end

  @spec fetch_owned_proposal(pos_integer(), pos_integer(), pos_integer()) ::
          {:ok, PlanningProposal.t(), PlanningGenerationRun.t()} | {:error, :proposal_not_found}
  def fetch_owned_proposal(proposal_id, account_id, user_id) do
    query =
      from(p in PlanningProposal,
        join: r in assoc(p, :generation_run),
        where: p.id == ^proposal_id and r.account_id == ^account_id and r.user_id == ^user_id,
        preload: [generation_run: []]
      )

    case Repo.one(query) do
      nil ->
        {:error, :proposal_not_found}

      proposal ->
        {:ok, run} =
          Repo.all(from(r in PlanningGenerationRun, where: r.id == ^proposal.generation_run_id))
          |> case do
            [run] -> {:ok, run}
            [] -> {:error, :not_found}
          end

        {:ok, proposal, run}
    end
  end

  # -------------------------------------------------------------------------
  # Scheduled meals
  # -------------------------------------------------------------------------

  @spec schedule_meal(map()) :: {:ok, ScheduledMeal.t()} | {:error, Ecto.Changeset.t()}
  def schedule_meal(attrs),
    do: %ScheduledMeal{} |> ScheduledMeal.changeset(attrs) |> Repo.insert()

  @spec update_scheduled_meal(ScheduledMeal.t(), map()) ::
          {:ok, ScheduledMeal.t()} | {:error, Ecto.Changeset.t()}
  def update_scheduled_meal(meal, attrs),
    do: meal |> ScheduledMeal.changeset(attrs) |> Repo.update()

  @spec list_scheduled_meals(pos_integer(), Date.t(), Date.t()) :: [ScheduledMeal.t()]
  def list_scheduled_meals(account_id, from_date, to_date) do
    from(m in ScheduledMeal,
      where: m.account_id == ^account_id and m.date >= ^from_date and m.date <= ^to_date,
      order_by: [asc: m.date, asc: m.slot]
    )
    |> Repo.all()
  end

  @spec list_uncooked_scheduled_meals(pos_integer(), Date.t(), Date.t()) :: [ScheduledMeal.t()]
  def list_uncooked_scheduled_meals(account_id, from_date, to_date) do
    from(m in ScheduledMeal,
      where:
        m.account_id == ^account_id and m.is_cooked == false and m.date >= ^from_date and
          m.date <= ^to_date
    )
    |> Repo.all()
  end

  @spec list_uncooked_scheduled_meals_with_recipe_ingredients(pos_integer(), Date.t(), Date.t()) ::
          [
            ScheduledMeal.t()
          ]
  def list_uncooked_scheduled_meals_with_recipe_ingredients(account_id, from_date, to_date) do
    from(m in ScheduledMeal,
      where:
        m.account_id == ^account_id and m.is_cooked == false and m.date >= ^from_date and
          m.date <= ^to_date,
      preload: [
        recipe: [
          recipe_ingredients: [:ingredient]
        ]
      ]
    )
    |> Repo.all()
  end

  @spec get_scheduled_meal!(pos_integer()) :: ScheduledMeal.t()
  def get_scheduled_meal!(id), do: Repo.get!(ScheduledMeal, id)

  @spec get_scheduled_meal_for_account(pos_integer(), pos_integer()) :: ScheduledMeal.t() | nil
  def get_scheduled_meal_for_account(account_id, meal_id) do
    from(m in ScheduledMeal,
      where: m.id == ^meal_id and m.account_id == ^account_id,
      preload: [
        recipe: [
          :recipe_steps,
          recipe_ingredients: [:ingredient]
        ]
      ]
    )
    |> Repo.one()
  end

  @spec delete_scheduled_meal(pos_integer()) :: :ok
  def delete_scheduled_meal(id) do
    Repo.delete!(Repo.get!(ScheduledMeal, id))
    :ok
  end

  # -------------------------------------------------------------------------
  # Candidate recipes (exclusion filtering)
  # -------------------------------------------------------------------------

  @spec candidate_recipe_ids_for_slots(pos_integer(), [pos_integer()], [atom()]) :: [
          pos_integer()
        ]
  def candidate_recipe_ids_for_slots(account_id, user_ids, slots) when is_list(slots) do
    slot_strings = Enum.map(slots, &to_string/1)
    excluded_ids = Accounts.list_user_excluded_ingredient_ids(user_ids) |> MapSet.to_list()

    base_ids =
      from(r in Recipe,
        where: is_nil(r.account_id) or r.account_id == ^account_id,
        where: fragment("? && ?", r.suitable_for_slots, ^slot_strings),
        select: r.id
      )
      |> Repo.all()

    if excluded_ids == [] or base_ids == [] do
      base_ids
    else
      blocked_ids =
        from(ri in RecipeIngredient,
          where: ri.recipe_id in ^base_ids and ri.ingredient_id in ^excluded_ids,
          select: ri.recipe_id,
          distinct: true
        )
        |> Repo.all()
        |> MapSet.new()

      Enum.reject(base_ids, &MapSet.member?(blocked_ids, &1))
    end
  end

  @spec recipes_for_ids([pos_integer()], pos_integer()) :: [
          %{id: pos_integer(), name: String.t(), slot: atom(), source: String.t()}
        ]
  def recipes_for_ids(recipe_ids, account_id) when is_list(recipe_ids) do
    from(r in Recipe,
      where: r.id in ^recipe_ids,
      where: is_nil(r.account_id) or r.account_id == ^account_id,
      select: %{id: r.id, name: r.name, suitable_for_slots: r.suitable_for_slots}
    )
    |> Repo.all()
    |> Enum.flat_map(fn recipe ->
      Enum.map(recipe.suitable_for_slots, fn slot ->
        %{id: recipe.id, name: recipe.name, slot: slot, source: "candidate"}
      end)
    end)
  end

  # -------------------------------------------------------------------------
  # Cooking sessions
  # -------------------------------------------------------------------------

  @spec create_cooking_session(map()) :: {:ok, CookingSession.t()} | {:error, Ecto.Changeset.t()}
  def create_cooking_session(attrs),
    do: %CookingSession{} |> CookingSession.changeset(attrs) |> Repo.insert()

  @spec update_cooking_session(CookingSession.t(), map()) ::
          {:ok, CookingSession.t()} | {:error, Ecto.Changeset.t()}
  def update_cooking_session(session, attrs),
    do: session |> CookingSession.changeset(attrs) |> Repo.update()

  @spec get_cooking_session!(pos_integer()) :: CookingSession.t()
  def get_cooking_session!(id), do: Repo.get!(CookingSession, id)

  @spec get_cooking_session_for_account(pos_integer(), pos_integer()) :: CookingSession.t() | nil
  def get_cooking_session_for_account(account_id, session_id) do
    from(s in CookingSession,
      where: s.id == ^session_id and s.account_id == ^account_id,
      preload: [
        :chat_messages,
        :context_snapshots,
        scheduled_meal: [
          recipe: [
            :recipe_steps,
            recipe_ingredients: [:ingredient]
          ]
        ]
      ]
    )
    |> Repo.one()
  end

  @spec add_chat_message(map()) :: {:ok, CookingChatMessage.t()} | {:error, Ecto.Changeset.t()}
  def add_chat_message(attrs),
    do: %CookingChatMessage{} |> CookingChatMessage.changeset(attrs) |> Repo.insert()

  @spec add_step_event(map()) :: {:ok, CookingStepEvent.t()} | {:error, Ecto.Changeset.t()}
  def add_step_event(attrs),
    do: %CookingStepEvent{} |> CookingStepEvent.changeset(attrs) |> Repo.insert()

  @spec add_context_snapshot(map()) :: {:ok, ContextSnapshot.t()} | {:error, Ecto.Changeset.t()}
  def add_context_snapshot(attrs),
    do: %ContextSnapshot{} |> ContextSnapshot.changeset(attrs) |> Repo.insert()

  @spec latest_context_snapshot(pos_integer()) :: ContextSnapshot.t() | nil
  def latest_context_snapshot(session_id) do
    from(cs in ContextSnapshot,
      where: cs.cooking_session_id == ^session_id,
      order_by: [desc: cs.captured_at],
      limit: 1
    )
    |> Repo.one()
  end

  # -------------------------------------------------------------------------
  # Favorites (lightweight read)
  # -------------------------------------------------------------------------

  @spec list_recent_favorites(pos_integer(), pos_integer(), pos_integer()) :: [
          %{
            recipe_id: pos_integer(),
            recipe_name: String.t(),
            suitable_for_slots: [atom()],
            prep_time_minutes: integer(),
            calories_per_serving: float()
          }
        ]
  def list_recent_favorites(account_id, user_id, limit \\ 10) do
    from(f in FavoriteRecipe,
      where: f.account_id == ^account_id and f.user_id == ^user_id,
      join: r in assoc(f, :recipe),
      order_by: [desc: f.inserted_at],
      limit: ^limit,
      select: %{
        recipe_id: f.recipe_id,
        recipe_name: r.name,
        suitable_for_slots: r.suitable_for_slots,
        prep_time_minutes: r.prep_time_minutes,
        calories_per_serving: r.calories_per_serving
      }
    )
    |> Repo.all()
  end

  # -------------------------------------------------------------------------
  # Slot favorites (instance-level)
  # -------------------------------------------------------------------------

  @spec toggle_slot_favorite(map()) :: {:ok, map()} | {:error, term()}
  def toggle_slot_favorite(%{
        account_id: account_id,
        user_id: user_id,
        date: date,
        slot: slot
      }) do
    existing =
      from(sf in SlotFavorite,
        where:
          sf.account_id == ^account_id and
            sf.user_id == ^user_id and
            sf.date == ^date and
            sf.slot == ^slot
      )
      |> Repo.one()

    if existing do
      Repo.delete!(existing)
      {:ok, %{status: :removed, date: date, slot: slot}}
    else
      attrs = %{account_id: account_id, user_id: user_id, date: date, slot: slot}
      %SlotFavorite{} |> SlotFavorite.changeset(attrs) |> Repo.insert()
    end
  end

  @spec is_slot_favorite?(pos_integer(), pos_integer(), Date.t(), String.t()) :: boolean()
  def is_slot_favorite?(account_id, user_id, date, slot) do
    Repo.exists?(
      from(sf in SlotFavorite,
        where:
          sf.account_id == ^account_id and
            sf.user_id == ^user_id and
            sf.date == ^date and
            sf.slot == ^slot
      )
    )
  end

  @spec list_slot_favorites(pos_integer(), pos_integer()) :: [SlotFavorite.t()]
  def list_slot_favorites(account_id, user_id) do
    from(sf in SlotFavorite,
      where: sf.account_id == ^account_id and sf.user_id == ^user_id,
      order_by: [asc: sf.date, asc: sf.slot],
      preload: [:scheduled_meal, :recipe]
    )
    |> Repo.all()
  end

  # -------------------------------------------------------------------------
  # Recipe pricing for optimizer
  # -------------------------------------------------------------------------

  @doc """
  Returns the latest historical cost per recipe_id from recipe_daily_costs.
  Returns 0 for recipes with no cost data.
  """
  @spec latest_recipe_costs([pos_integer()]) :: %{pos_integer() => non_neg_integer()}
  def latest_recipe_costs(recipe_ids) when is_list(recipe_ids) do
    recipe_ids
    |> Enum.into(%{}, &{&1, 0})
    |> Map.merge(latest_recipe_costs_query(recipe_ids))
  end

  defp latest_recipe_costs_query(recipe_ids) do
    from(rdc in RecipeDailyCost,
      where: rdc.recipe_id in ^recipe_ids,
      order_by: [desc: rdc.date],
      select: {rdc.recipe_id, rdc.total_cents_ars}
    )
    |> Repo.all()
    |> Enum.reduce(%{}, fn
      {recipe_id, cost}, acc -> Map.put_new(acc, recipe_id, cost)
    end)
  end
end
