defmodule MealPlannerApi.Generation.Server do
  @moduledoc """
  OTP GenServer que orquesta el pipeline completo de generación de menús.

  Un proceso por `account_id` via Registry. El PlanningChannel lo usa para
  coordinar el flujo completo:

  1. Recibe `start_generation` → crea GenerationRun + Proposal (`:pending`)
  2. Construye constraints y slot list desde PriceService
  3. Llama a PythonClient.optimize_menu()
  4. Actualiza proposal_json con slots resueltos
  5. hace broadcast `proposal_ready` al canal
  6. Chat/modificación → re-optimiza slots específicos
  7. Confirm/Reject → persiste ScheduledMeals, limpia estado

  States: `:idle` → `:generating` → `:completed` → `:idle` (o `:error`)
  """

  use GenServer, restart: :temporary
  require Logger

  alias MealPlannerApi.Data.{
    PlanningRepo,
    RecipeRepo,
    UserPreferenceRepo
  }

  alias Ecto.Multi
  alias MealPlannerApi.Optimization.OptimizerServer
  alias MealPlannerApi.Optimization.PayloadAdapter
  alias MealPlannerApi.Persistence.Planning.PlanningGenerationRun
  alias MealPlannerApi.Persistence.Planning.PlanningProposal
  alias MealPlannerApi.Persistence.Planning.ScheduledMeal
  alias MealPlannerApi.Services.GenerationService
  alias MealPlannerApi.Services.PriceService
  alias MealPlannerApi.Services.ShoppingService
  alias MealPlannerApi.Repo

  # -------------------------------------------------------------------------
  # Types
  # -------------------------------------------------------------------------

  @type state :: %{
          account_id: pos_integer(),
          user_id: pos_integer(),
          channel_pid: pid() | nil,
          phase: :idle | :generating | :completed | :error,
          current_run_id: pos_integer() | nil,
          current_proposal_id: pos_integer() | nil,
          proposal_json: map() | nil,
          constraints: map() | nil
        }

  @type reason :: :already_running | :not_found | :forbidden | :optimization_failed | term()

  # -------------------------------------------------------------------------
  # Via constructor
  # -------------------------------------------------------------------------

  @doc "Construye el registro `{:via, Registry, {Generations, key}}` para este account."
  @spec via(pos_integer() | String.t()) :: GenServer.name()
  def via(account_id)
      when (is_integer(account_id) and account_id > 0) or
             (is_binary(account_id) and account_id != "") do
    key = {:generation, account_id}
    {:via, Registry, {MealPlannerApi.Generation.Generations, key}}
  end

  # -------------------------------------------------------------------------
  # Client API
  # -------------------------------------------------------------------------

  @spec start_link(account_id: pos_integer(), user_id: pos_integer()) :: GenServer.on_start()
  def start_link(opts) do
    account_id = Keyword.fetch!(opts, :account_id)
    name = via(account_id)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec start_generation(pos_integer(), pos_integer(), map(), pid()) ::
          {:ok, run_id :: pos_integer()} | {:error, reason()}
  def start_generation(account_id, user_id, constraints, channel_pid) do
    case Registry.lookup(MealPlannerApi.Generation.Generations, {:generation, account_id}) do
      [{pid, _}] ->
        GenServer.call(pid, {:start_generation, user_id, constraints, channel_pid})

      [] ->
        start_and_call(account_id, user_id, constraints, channel_pid)
    end
  end

  @spec chat(pid(), proposal_id :: pos_integer(), message :: String.t()) :: :ok
  def chat(pid, proposal_id, message) when is_pid(pid) do
    GenServer.cast(pid, {:chat, proposal_id, message})
  end

  @spec confirm(pid(), proposal_id :: pos_integer()) ::
          {:ok, map()} | {:error, reason()}
  def confirm(pid, proposal_id) when is_pid(pid) do
    GenServer.call(pid, {:confirm, proposal_id})
  end

  @spec reject(pid(), proposal_id :: pos_integer()) :: :ok
  def reject(pid, proposal_id) when is_pid(pid) do
    GenServer.cast(pid, {:reject, proposal_id})
  end

  @spec get_status(pos_integer()) :: state() | nil
  def get_status(account_id) do
    case Registry.lookup(MealPlannerApi.Generation.Generations, {:generation, account_id}) do
      [{pid, _}] -> GenServer.call(pid, :get_status)
      [] -> nil
    end
  end

  # -------------------------------------------------------------------------
  # Callbacks
  # -------------------------------------------------------------------------

  @impl true
  def init(opts) do
    account_id = Keyword.fetch!(opts, :account_id)
    user_id = Keyword.get(opts, :user_id)

    {:ok,
     %{
       account_id: account_id,
       user_id: user_id,
       channel_pid: nil,
       phase: :idle,
       current_run_id: nil,
       current_proposal_id: nil,
       proposal_json: nil,
       constraints: nil
     }}
  end

  @impl true
  def handle_call({:start_generation, user_id, constraints, channel_pid}, _from, state) do
    if state.phase == :generating do
      {:reply, {:error, :already_running}, state}
    else
      {:ok, run} = create_run(state.account_id, user_id, constraints)
      {:ok, proposal} = create_proposal(run.id)

      new_state =
        %{
          state
          | channel_pid: channel_pid,
            phase: :generating,
            current_run_id: run.id,
            current_proposal_id: proposal.id,
            proposal_json: %{slots: []},
            constraints: constraints
        }

      send(self(), :run_optimization)
      {:reply, {:ok, run.id}, new_state}
    end
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_call({:confirm, proposal_id}, _from, state) do
    case do_confirm(state, proposal_id) do
      {:ok, _result} = reply ->
        # Post-review fix (item 3, continued): the pre-existing code called
        # `reset_state(state)` here but discarded its result instead of
        # returning it, so the GenServer's own `phase`/`current_run_id`/etc.
        # were never actually reset after a successful confirm — only fixed
        # now because this whole function is being made atomic anyway.
        {:reply, reply, reset_state(state)}

      {:error, _reason} = reply ->
        {:reply, reply, state}
    end
  end

  @impl true
  def handle_cast({:chat, proposal_id, message}, state) do
    handle_chat(state, proposal_id, message)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:reject, proposal_id}, state) do
    handle_reject(state, proposal_id)
    {:noreply, state}
  end

  @impl true
  def handle_info(:run_optimization, state) do
    new_state = run_pipeline(state)
    {:noreply, new_state}
  end

  # -------------------------------------------------------------------------
  # Pipeline
  # -------------------------------------------------------------------------

  defp start_and_call(account_id, user_id, constraints, channel_pid) do
    case DynamicSupervisor.start_child(
           MealPlannerApi.Generation.DynamicSupervisor,
           {__MODULE__, [account_id: account_id, user_id: user_id]}
         ) do
      {:ok, pid} ->
        GenServer.call(pid, {:start_generation, user_id, constraints, channel_pid})

      {:error, {:already_started, pid}} ->
        GenServer.call(pid, {:start_generation, user_id, constraints, channel_pid})

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_pipeline(state) do
    %{
      account_id: account_id,
      user_id: user_id,
      current_run_id: run_id,
      current_proposal_id: proposal_id,
      constraints: constraints
    } = state

    # 1. Perfil de usuario + recetas favoritas
    {user_profile, favorite_recipe_ids} = load_user_profile_and_favorites(account_id, user_id)

    # 2. Resolver constraints (favorite_recipe_ids injected below)
    resolved =
      GenerationService.build_constraints(user_profile, constraints)
      |> Map.put(:favorite_recipe_ids, favorite_recipe_ids)

    # 3. Slot list (with real candidate recipe ids per slot type)
    slots_input = build_slots_input(resolved, account_id, user_id)

    # 4. Recipe prices + macros
    # Recipe ids are UUIDs (binary_id), not integers — keep them as strings.
    all_recipe_ids =
      slots_input
      |> Enum.flat_map(&(&1[:available_recipe_ids] || []))
      |> Enum.uniq()

    recipe_prices = PriceService.fetch_recipe_prices_float(all_recipe_ids)
    recipe_macros = load_recipe_macros(all_recipe_ids)

    # 5. Build optimizer payload (translate format)
    optimizer_payload =
      PayloadAdapter.build_optimizer_payload(
        slots_input,
        convert_prices_to_string_keys(recipe_prices),
        convert_macros_to_string_keys(recipe_macros)
      )

    # 6. Get recipe data for response translation
    recipe_data = load_recipe_data_for_response(all_recipe_ids)

    # 7. Call OptimizerServer (Port/stdio, working integration)
    case OptimizerServer.select_weekly_menu(optimizer_payload) do
      {:ok, optimizer_result} ->
        # Translate response and enrich with DB data
        {:ok, optimized_slots} =
          PayloadAdapter.translate_response({:ok, optimizer_result}, recipe_data)

        proposal_json = GenerationService.build_proposal_json(optimized_slots)
        persist_proposal_result(proposal_id, run_id, proposal_json, state)

      {:error, reason} ->
        handle_optimization_error(run_id, reason, state)
    end
  rescue
    e ->
      Logger.error(
        "Generation.Server pipeline crashed account_id=#{inspect(state.account_id)} " <>
          "run_id=#{inspect(state.current_run_id)} kind=#{inspect(e.__struct__)}"
      )

      broadcast(state, "generation_error", %{reason: "pipeline_error"})
      %{state | phase: :error}
  end

  # -------------------------------------------------------------------------
  # Confirm / reject
  # -------------------------------------------------------------------------

  # Post-review fix (CRITICAL item 3): confirm used to run 3 independent
  # Repo calls (`update_proposal` -> `:accepted`, then N `schedule_meal`
  # inserts, filtering out `{:error, _}` results with `Enum.filter`) with NO
  # rollback. Any single conflicting `ScheduledMeal` (unique constraint on
  # `[:account_id, :date, :slot]` — e.g. a slot already scheduled by another
  # confirm/manual edit) silently dropped just THAT meal while the proposal
  # still ended up `:accepted` with fewer meals than the client was shown —
  # exactly the bug this fix exists to eliminate. Wrapped in `Ecto.Multi` so
  # any failure (proposal update, any one meal insert, or the run status
  # update) rolls back everything: proposal stays at its prior status, ZERO
  # meals persisted.
  defp do_confirm(state, proposal_id) do
    with :ok <- verify_ownership(proposal_id, state.account_id),
         {:ok, proposal, run} <- fetch_proposal_with_run(proposal_id) do
      proposal
      |> build_confirm_multi(run, state)
      |> Repo.transaction()
      |> handle_confirm_transaction(state, proposal_id)
    else
      {:error, _} = error -> error
    end
  end

  defp build_confirm_multi(proposal, run, state) do
    slots = get_in(proposal.proposal_json, ["slots"]) || []

    Multi.new()
    |> Multi.update(:proposal, PlanningProposal.changeset(proposal, %{status: :accepted}))
    |> add_scheduled_meal_steps(slots, state)
    |> Multi.update(
      :generation_run,
      PlanningGenerationRun.changeset(run, %{
        status: :completed,
        completed_at: DateTime.utc_now()
      })
    )
  end

  defp add_scheduled_meal_steps(multi, slots, state) do
    slots
    |> Enum.with_index()
    |> Enum.reduce(multi, fn {slot, index}, acc ->
      Multi.insert(acc, {:scheduled_meal, index}, scheduled_meal_changeset(slot, state))
    end)
  end

  defp scheduled_meal_changeset(slot, state) do
    [date, slot_name] = String.split(slot["slot_key"], "_", parts: 2)

    %ScheduledMeal{}
    |> ScheduledMeal.changeset(%{
      account_id: state.account_id,
      date: Date.from_iso8601!(date),
      slot: String.to_existing_atom(slot_name),
      recipe_id: parse_recipe_id(slot["recipe_id"]),
      is_cooked: false
    })
  end

  defp handle_confirm_transaction({:ok, changes}, state, proposal_id) do
    scheduled_count = count_scheduled_meal_steps(changes)

    broadcast(state, "proposal_confirmed", %{
      proposal_id: proposal_id,
      scheduled_meals_count: scheduled_count
    })

    trigger_shopping_list_sync(state.account_id, changes)

    {:ok, %{scheduled_meals_count: scheduled_count}}
  end

  defp handle_confirm_transaction({:error, step, reason, _changes_so_far}, _state, proposal_id) do
    log_confirm_transaction_failure(proposal_id, step, reason)
    {:error, :confirm_failed}
  end

  defp count_scheduled_meal_steps(changes) do
    changes
    |> Map.keys()
    |> Enum.count(&match?({:scheduled_meal, _index}, &1))
  end

  # Item 4: accepting the plan must also load the shopping list with the
  # week's ingredients — eagerly, not just on next lazy read. Runs AFTER the
  # confirm transaction commits (deliberately outside the Multi): if this
  # fails, the confirm itself still stands (meals are safely persisted) and
  # `ShoppingService.get_shopping_list/2`'s existing lazy
  # `ensure_shopping_items_from_schedule/3` call self-heals on next read —
  # only the "eager" convenience is lost, never the confirm.
  defp trigger_shopping_list_sync(account_id, changes) do
    dates =
      changes
      |> Enum.filter(fn {key, _} -> match?({:scheduled_meal, _}, key) end)
      |> Enum.map(fn {_key, meal} -> meal.date end)

    case dates do
      [] ->
        :ok

      _ ->
        from_date = Enum.min(dates, Date)
        to_date = Enum.max(dates, Date)
        ShoppingService.ensure_shopping_items_from_schedule(account_id, from_date, to_date)
    end
  rescue
    e ->
      Logger.error(
        "Generation.Server post-confirm shopping list sync failed account_id=#{inspect(account_id)} kind=#{inspect(e.__struct__)}"
      )

      :ok
  end

  defp log_confirm_transaction_failure(proposal_id, step, %Ecto.Changeset{errors: errors}) do
    Logger.error(
      "Generation.Server confirm transaction failed proposal_id=#{inspect(proposal_id)} " <>
        "step=#{inspect(step)} changeset_errors=#{inspect(errors)}"
    )
  end

  defp log_confirm_transaction_failure(proposal_id, step, reason) do
    Logger.error(
      "Generation.Server confirm transaction failed proposal_id=#{inspect(proposal_id)} " <>
        "step=#{inspect(step)} reason=#{inspect(reason)}"
    )
  end

  defp handle_reject(state, proposal_id) do
    with :ok <- verify_ownership(proposal_id, state.account_id),
         {:ok, proposal, run} <- fetch_proposal_with_run(proposal_id),
         {:ok, _} <- PlanningRepo.update_proposal(proposal, %{status: :rejected}) do
      PlanningRepo.update_generation_run(run, %{
        status: :completed,
        completed_at: DateTime.utc_now()
      })

      broadcast(state, "proposal_rejected", %{proposal_id: proposal_id})
    end
  end

  # -------------------------------------------------------------------------
  # Chat / modificación
  # -------------------------------------------------------------------------

  defp handle_chat(state, _proposal_id, msg) do
    case GenerationService.parse_modification(msg) do
      {:ok, parsed} ->
        new_state = apply_modification_to_state(state, parsed)

        broadcast(new_state, "proposal_update", %{
          change_type: parsed.change_type,
          new_value: parsed.new_value
        })

        {:noreply, new_state}

      {:error, _} ->
        broadcast(state, "generation_error", %{reason: "invalid_modification"})
        {:noreply, state}
    end
  end

  defp apply_modification_to_state(state, %{
         change_type: :remove_ingredient,
         new_value: ingredient
       }) do
    current = state.constraints || %{}
    exclusions = Map.get(current, :excluded_ingredients, [])

    updated = %{
      state
      | constraints: Map.put(current, :excluded_ingredients, exclusions ++ [ingredient])
    }

    send(self(), :run_optimization)
    updated
  end

  defp apply_modification_to_state(state, %{change_type: :lower_price}) do
    current = state.constraints || %{}
    budget = Map.get(current, :budget_cents, 10_000)
    updated = %{state | constraints: Map.put(current, :budget_cents, div(budget * 80, 100))}
    send(self(), :run_optimization)
    updated
  end

  defp apply_modification_to_state(state, %{change_type: :higher_protein}) do
    current = state.constraints || %{}
    protein = Map.get(current, :protein_g_per_meal, 25)
    updated = %{state | constraints: Map.put(current, :protein_g_per_meal, protein + 10)}
    send(self(), :run_optimization)
    updated
  end

  defp apply_modification_to_state(state, %{change_type: :change_recipe, slot_key: _sk}) do
    send(self(), :run_optimization)
    state
  end

  # -------------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------------

  defp create_run(account_id, user_id, constraints) do
    PlanningRepo.create_generation_run(%{
      account_id: account_id,
      user_id: user_id,
      status: :processing,
      started_at: DateTime.utc_now(),
      input_context: %{
        constraints: constraints,
        generated_by: "generation_server_v2"
      }
    })
  end

  defp create_proposal(run_id) do
    PlanningRepo.create_proposal(%{
      generation_run_id: run_id,
      proposal_json: %{slots: []},
      status: :pending
    })
  end

  defp load_user_profile(user_id) do
    UserPreferenceRepo.get(user_id) ||
      %{protein_g_per_meal: 25, default_exclusions: [], default_budget_cents: 10_000}
  end

  defp load_user_profile_and_favorites(account_id, user_id) do
    profile = load_user_profile(user_id)

    favorite_ids =
      RecipeRepo.list_favorite_ids(account_id)
      |> Enum.map(& &1.id)

    {profile, favorite_ids}
  end

  # Public (not `defp`) so the test suite can exercise the REAL production
  # slot/candidate wiring directly — building the exact `available_recipe_ids`
  # per slot that reaches `PayloadAdapter.build_optimizer_payload/3` — instead
  # of re-deriving an equivalent query by hand. Same rationale as
  # `Accounts.build_identity_multi/4`: the private helper stays the single
  # source of truth, only visibility changes.
  @doc false
  @spec build_slots_input(map(), pos_integer() | String.t(), pos_integer() | String.t()) :: [
          map()
        ]
  def build_slots_input(constraints, account_id, user_id) do
    date_from =
      constraints["date_from"] || constraints[:date_from] ||
        Date.utc_today() |> Date.to_iso8601()

    date_to =
      constraints["date_to"] || constraints[:date_to] ||
        Date.add(Date.utc_today(), 6) |> Date.to_iso8601()

    slot_types =
      constraints["slot_types"] || constraints[:slot_types] || [:breakfast, :lunch, :dinner]

    # Extract favorite IDs from constraints and convert to strings for JSON
    favorite_ids =
      (constraints[:favorite_recipe_ids] || [])
      |> Enum.map(&to_string/1)

    candidates_by_slot_type = build_candidates_by_slot_type(account_id, user_id, slot_types)

    for date <- Date.range(Date.from_iso8601!(date_from), Date.from_iso8601!(date_to)),
        slot <- slot_types do
      slot_str = to_string(slot)

      %{
        date: Date.to_iso8601(date),
        slot: slot_str,
        available_recipe_ids: Map.get(candidates_by_slot_type, slot_str, []),
        constraints: %{
          "budget_cents" => constraints["budget_cents"] || 10_000,
          "protein_g" => constraints["protein_g"] || 25,
          "max_calories" => constraints["max_calories"] || 800,
          "excluded_recipe_ids" => [],
          "excluded_ingredients" => [],
          "preferred_recipe_ids" => favorite_ids
        }
      }
    end
  end

  # Resolves real candidate recipe ids per (unique) slot type, scoped to the
  # account (owned or global recipes) and filtered against the requesting
  # user's excluded ingredients — reusing the same query the legacy
  # PlanningService pipeline already relies on
  # (`PlanningRepo.candidate_recipe_ids_for_slots/3`). Computed once per slot
  # type (not per date) since candidates don't vary by date.
  @spec build_candidates_by_slot_type(pos_integer() | String.t(), pos_integer() | String.t(), [
          atom() | String.t()
        ]) :: %{String.t() => [String.t()]}
  defp build_candidates_by_slot_type(account_id, user_id, slot_types) do
    slot_types
    |> Enum.map(&to_string/1)
    |> Enum.uniq()
    |> Enum.into(%{}, fn slot_str ->
      ids =
        PlanningRepo.candidate_recipe_ids_for_slots(account_id, [user_id], [slot_str])
        |> Enum.map(&to_string/1)

      {slot_str, ids}
    end)
  end

  # Public (not `defp`) — same rationale as `build_slots_input/3` above.
  @doc false
  def load_recipe_macros(recipe_ids) do
    recipe_ids
    |> RecipeRepo.list_by_ids()
    |> Enum.into(%{}, fn recipe ->
      {to_string(recipe.id),
       %{
         protein_g: to_float(recipe.protein_g_per_serving),
         calories: to_float(recipe.calories_per_serving),
         carbs_g: to_float(recipe.carbs_g_per_serving)
       }}
    end)
  end

  @spec load_recipe_data_for_response([String.t()]) :: %{String.t() => map()}
  defp load_recipe_data_for_response(recipe_ids) do
    recipe_ids
    |> RecipeRepo.list_by_ids_with_prices()
    |> Enum.into(%{}, fn recipe ->
      {to_string(recipe.id),
       %{
         name: recipe.name,
         price_cents: (recipe.recipe_price && recipe.recipe_price.price_per_serving_cents) || 0,
         protein_g: to_float(recipe.protein_g_per_serving),
         calories: to_float(recipe.calories_per_serving),
         carbs_g: to_float(recipe.carbs_g_per_serving)
       }}
    end)
  end

  # Convert integer-keyed map to string-keyed map for PayloadAdapter
  defp convert_prices_to_string_keys(prices) do
    prices
    |> Enum.map(fn {k, v} -> {to_string(k), v} end)
    |> Enum.into(%{})
  end

  # Convert integer-keyed map to string-keyed map for PayloadAdapter
  defp convert_macros_to_string_keys(macros) do
    macros
    |> Enum.map(fn {k, v} -> {to_string(k), v} end)
    |> Enum.into(%{})
  end

  defp persist_proposal_result(proposal_id, run_id, proposal_json, state) do
    proposal = Repo.get!(MealPlannerApi.Persistence.Planning.PlanningProposal, proposal_id)
    PlanningRepo.update_proposal(proposal, %{proposal_json: proposal_json})

    run = Repo.get!(MealPlannerApi.Persistence.Planning.PlanningGenerationRun, run_id)

    PlanningRepo.update_generation_run(run, %{
      status: :completed,
      completed_at: DateTime.utc_now()
    })

    broadcast(state, "proposal_ready", %{
      proposal_id: proposal_id,
      run_id: run_id,
      proposal: proposal_json
    })

    %{state | phase: :completed, proposal_json: proposal_json}
  end

  defp handle_optimization_error(run_id, reason, state) do
    run = Repo.get!(MealPlannerApi.Persistence.Planning.PlanningGenerationRun, run_id)
    PlanningRepo.update_generation_run(run, %{status: :error, completed_at: DateTime.utc_now()})

    broadcast(state, "generation_error", %{run_id: run_id, reason: Atom.to_string(reason)})
    %{state | phase: :error}
  end

  # `state.channel_pid` is the raw pid of the joined PlanningChannel process
  # (`socket.channel_pid`), not a `%Phoenix.Socket{}` struct, so we can't use
  # `Phoenix.Channel.broadcast!/3` (it requires a joined socket). Instead we
  # broadcast straight to the channel's topic via the Endpoint's PubSub —
  # every socket joined to `"planning:#{account_id}"` (including the one
  # backed by `channel_pid`) receives it through the channel's default
  # `handle_out/3`, which is exactly how GenerationServer -> Channel -> client
  # push is meant to work in Phoenix.
  defp broadcast(state, event, payload) do
    if state.channel_pid && Process.alive?(state.channel_pid) do
      MealPlannerApiWeb.Endpoint.broadcast("planning:#{state.account_id}", event, payload)
    end
  end

  # Post-review fix (item 3): both used to be `Repo.get!/2` — raising
  # `Ecto.NoResultsError` for a bogus/deleted `proposal_id` instead of
  # returning `{:error, :not_found}`. Since `do_confirm/2` and
  # `handle_reject/2` run inside a live GenServer's `handle_call`/`handle_cast`
  # callback (not wrapped in a `rescue`), that exception used to CRASH the
  # entire per-account GenServer — losing its in-flight state for any other
  # legitimate concurrent operation — instead of gracefully erroring back to
  # the caller the way the `PlanningChatService` fallback path already does.
  defp fetch_proposal(id) do
    case Repo.get(PlanningProposal, id) do
      nil -> {:error, :not_found}
      proposal -> {:ok, proposal}
    end
  end

  defp fetch_proposal_with_run(proposal_id) do
    with {:ok, proposal} <- fetch_proposal(proposal_id) do
      case Repo.get(PlanningGenerationRun, proposal.generation_run_id) do
        nil -> {:error, :not_found}
        run -> {:ok, proposal, run}
      end
    end
  end

  defp verify_ownership(proposal_id, account_id) do
    case fetch_proposal_with_run(proposal_id) do
      {:ok, _proposal, run} ->
        if run.account_id == account_id, do: :ok, else: {:error, :forbidden}

      _ ->
        {:error, :not_found}
    end
  end

  defp reset_state(state) do
    %{
      state
      | channel_pid: nil,
        phase: :idle,
        current_run_id: nil,
        current_proposal_id: nil,
        proposal_json: nil,
        constraints: nil
    }
  end

  # Recipe ids are UUIDs (binary_id) post-tenancy-refactor, not integers —
  # pass them through as-is instead of attempting `Integer.parse/1` (which
  # would always fail on a UUID and silently null out every scheduled meal's
  # recipe_id).
  defp parse_recipe_id(nil), do: nil
  defp parse_recipe_id(id) when is_binary(id), do: id
  defp parse_recipe_id(_), do: nil

  # Recipe macro columns (protein_g/carbs_g/fat_g) are `:decimal` — Jason
  # encodes `Decimal` as a JSON *string*, which the Python optimizer's
  # `_candidate_num` treats as 0 (it only accepts int/float), silently
  # zeroing out real macros. Normalize to float before they ever reach the
  # optimizer payload.
  defp to_float(nil), do: 0
  defp to_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp to_float(n) when is_number(n), do: n
end
