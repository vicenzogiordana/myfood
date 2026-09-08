defmodule MealPlannerApi.Generation.Server do
  @moduledoc """
  OTP GenServer que orquesta el pipeline completo de generación de menús.

  Un proceso por `account_id` via Registry. El PlanningChannel lo usa para
  coordinar el flujo completo:

  1. Recibe `start_generation` → crea GenerationRun + Proposal (`:pending`)
  2. Construye constraints y slot list desde PriceService
   3. Llama a OptimizerServer.select_weekly_menu()
  4. Actualiza proposal_json con slots resueltos
  5. hace broadcast `proposal_ready` al canal
  6. Chat/modificación → re-optimiza slots específicos
  7. Confirm/Reject → persiste ScheduledMeals, limpia estado

  States: `:idle` → `:generating` → `:completed` → `:idle` (o `:error`)
  """

  use GenServer, restart: :temporary

  alias MealPlannerApi.Data.{
    PlanningRepo,
    RecipeRepo,
    ShoppingRepo,
    UserPreferenceRepo
  }

  alias MealPlannerApi.Optimization.OptimizerServer
  alias MealPlannerApi.Optimization.PayloadAdapter
  alias MealPlannerApi.Persistence.Planning.PlanningSession
  alias MealPlannerApi.Services.GenerationService
  alias MealPlannerApi.Services.PriceService
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
  @spec via(pos_integer() | binary()) :: GenServer.name()
  def via(account_id) when is_integer(account_id) and account_id > 0 do
    key = {:generation, account_id}
    {:via, Registry, {MealPlannerApi.Generation.Generations, key}}
  end

  def via(account_id) when is_binary(account_id) and account_id != "" do
    # Compatibility shim: Phase A — Tenancy Refactor migrated the
    # `accounts.id` column from `:id` (integer) to `:binary_id` (UUID)
    # without updating this guard. Production `PlanningChannel`
    # passes `membership.account_id` (UUID) into `start_generation/4`,
    # which on a cold start hits this `via/1` and would otherwise
    # crash with `FunctionClauseError`. See planning-shopping-extraction
    # design §2 + tasks.md @task 3.2.
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

  @spec confirm(pid(), proposal_id :: pos_integer(), session_id :: Ecto.UUID.t()) ::
          {:ok, map()} | {:error, reason()}
  def confirm(pid, proposal_id, session_id) when is_pid(pid) do
    GenServer.call(pid, {:confirm, proposal_id, session_id})
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
    # Optional pre-population for tests (channel-layer end-to-end coverage
    # at @task 4.3 in `planning-shopping-extraction`). Production callers
    # (`PlanningChannel.handle_in("generate_menu", ...)`) set this via
    # the `:start_generation` cast flow; the test path registers the
    # server directly with the test process as `channel_pid`.
    initial_channel_pid = Keyword.get(opts, :channel_pid)

    {:ok,
     %{
       account_id: account_id,
       user_id: user_id,
       channel_pid: initial_channel_pid,
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
  def handle_call({:confirm, proposal_id, session_id}, _from, state) do
    reply = do_confirm(state, proposal_id, session_id)
    {:reply, reply, state}
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
           MealPlannerApi.Generation.Supervisor,
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

    # 3. Slot list
    slots_input = build_slots_input(resolved)

    # 4. Recipe prices + macros
    all_recipe_ids =
      slots_input
      |> Enum.flat_map(&(&1["available_recipe_ids"] || []))
      |> Enum.map(&String.to_integer/1)
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
    _ ->
      broadcast(state, "generation_error", %{reason: "pipeline_error"})
      %{state | phase: :error}
  end

  # -------------------------------------------------------------------------
  # Confirm / reject
  # -------------------------------------------------------------------------

  defp do_confirm(state, proposal_id, session_id) do
    with :ok <- verify_ownership(proposal_id, state.account_id),
         {:ok, proposal, run} <- fetch_proposal_with_run(proposal_id),
         :ok <- guard_not_already_confirmed(proposal),
         :ok <- verify_session_lock(state.account_id, session_id),
         {:ok, summary} <-
           run_confirm_transaction(state, proposal, run, session_id) do
      PlanningRepo.update_generation_run(run, %{
        status: :completed,
        completed_at: DateTime.utc_now()
      })

      broadcast(state, "proposal_confirmed", summary)

      reset_state(state)
      {:ok, summary}
    else
      {:error, _} = error -> error
    end
  end

  # PR2 of issue #35 — PlanningSession lock pre-check. The session MUST
  # exist, belong to this Account, be `:active`, and have an unexpired
  # lease. Any other state is rejected before any write. The session
  # transition to `:committed` happens later, INSIDE the same Multi as
  # the meals + cart writes, via `PlanningRepo.mark_committed/3`.
  defp verify_session_lock(account_id, session_id) do
    with {:ok, uuid} <- cast_session_id(session_id),
         {:ok, session} <- fetch_session_for_confirm(account_id, uuid),
         :ok <- classify_session_for_confirm(session),
         do: :ok
  end

  defp cast_session_id(session_id) when is_binary(session_id) do
    case Ecto.UUID.cast(session_id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :missing_lock}
    end
  end

  defp cast_session_id(_), do: {:error, :missing_lock}

  defp fetch_session_for_confirm(account_id, session_id) do
    case Repo.get(PlanningSession, session_id) do
      nil -> {:error, :missing_lock}
      %PlanningSession{account_id: ^account_id} = session -> {:ok, session}
      %PlanningSession{} -> {:error, :foreign_lock}
    end
  end

  defp classify_session_for_confirm(%PlanningSession{status: :active} = session) do
    if lease_active?(session.lease_expires_at) do
      :ok
    else
      # Lease expired — flip to :lost_lock OUTSIDE the main Multi so the
      # audit row is correct even if the transaction later aborts.
      PlanningRepo.mark_lost_lock(session.account_id, session.id)
      {:error, :lost_lock}
    end
  end

  defp classify_session_for_confirm(%PlanningSession{status: :lost_lock}),
    do: {:error, :lost_lock}

  defp classify_session_for_confirm(%PlanningSession{status: status})
       when status in [:committed, :cancelled, :expired],
       do: {:error, :terminal_lock}

  # Half-open lease window (matches `AccountAccess.trial_active?/2`).
  # A `nil` lease is treated as expired.
  defp lease_active?(%DateTime{} = lease),
    do: DateTime.compare(lease, DateTime.utc_now()) == :gt

  defp lease_active?(_), do: false

  # Wraps the scheduled-meals + cart writes in a single DB transaction so
  # either both persist or neither does. PR2 of issue #35 converted this
  # to one `Ecto.Multi` — the first step (`PlanningRepo.mark_committed/3`)
  # row-locks the session via `SELECT ... FOR UPDATE` and transitions
  # `:active` → `:committed` inside the same transaction as the meals,
  # cart, and proposal writes. The pre-check in `verify_session_lock/2`
  # has already classified the session; if it passes, the Multi step is
  # guaranteed to find an `:active` row.
  defp run_confirm_transaction(state, proposal, _run, session_id) do
    multi =
      Ecto.Multi.new()
      |> PlanningRepo.mark_committed(state.account_id, session_id)
      |> Ecto.Multi.run(:accept_proposal, fn _repo, _changes ->
        PlanningRepo.update_proposal(proposal, %{status: :accepted})
      end)
      |> Ecto.Multi.run(:scheduled_meals, fn _repo, _changes ->
        persist_scheduled_meals(proposal, state)
      end)
      |> Ecto.Multi.run(:shopping_cart, fn _repo, %{scheduled_meals: scheduled} ->
        persist_shopping_cart(scheduled, state)
      end)

    case Repo.transaction(multi) do
      {:ok, %{scheduled_meals: scheduled, shopping_cart: cart_summary}} ->
        {:ok,
         %{
           proposal_id: proposal.id,
           scheduled_meals_count: length(scheduled),
           cart: cart_summary.cart,
           shopping_items_count: cart_summary.lines_count,
           checkout_session_id: cart_summary.checkout_session_id
         }}

      {:error, _step, _reason, _changes} ->
        {:error, :transaction_failed}
    end
  end

  # Re-confirm idempotency guard (planning-shopping-extraction design §3 Decision 5).
  # A proposal already in :accepted status must NOT trigger any write — no
  # second `CheckoutSession` and no extra `ShoppingItem` rows. Concurrency:
  # `update_proposal(:accepted)` in the next call serializes on the row,
  # so a race between two confirms still terminates with at most one cart.
  defp guard_not_already_confirmed(%{status: :accepted}), do: {:error, :already_confirmed}
  defp guard_not_already_confirmed(_proposal), do: :ok

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

  defp build_slots_input(constraints) do
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

    for date <- Date.range(Date.from_iso8601!(date_from), Date.from_iso8601!(date_to)),
        slot <- slot_types do
      %{
        "date" => Date.to_iso8601(date),
        "slot" => to_string(slot),
        "available_recipe_ids" => [],
        "constraints" => %{
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

  defp load_recipe_macros(recipe_ids) do
    recipe_ids
    |> RecipeRepo.list_by_ids()
    |> Enum.into(%{}, fn recipe ->
      {to_string(recipe.id),
       %{
         protein_g: recipe.protein_g_per_serving || 0,
         calories: recipe.calories_per_serving || 0,
         carbs_g: recipe.carbs_g_per_serving || 0
       }}
    end)
  end

  @spec load_recipe_data_for_response([pos_integer()]) :: %{String.t() => map()}
  defp load_recipe_data_for_response(recipe_ids) do
    recipe_ids
    |> RecipeRepo.list_by_ids_with_prices()
    |> Enum.into(%{}, fn recipe ->
      {to_string(recipe.id),
       %{
         name: recipe.name,
         price_cents: (recipe.recipe_price && recipe.recipe_price.price_per_serving_cents) || 0,
         protein_g: recipe.protein_g_per_serving || 0,
         calories: recipe.calories_per_serving || 0,
         carbs_g: recipe.carbs_g_per_serving || 0
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

  defp broadcast(state, event, payload) do
    # Compatibility fix (planning-shopping-extraction @task 4.3):
    # `Phoenix.Channel.broadcast!/3` accepts a Socket struct only and
    # calls `assert_joined!/1` on the first argument. The pre-existing
    # call passed `state.channel_pid` (a pid), which crashes with
    # `FunctionClauseError`. Switch to `Phoenix.Channel.Server.broadcast!/4`
    # which takes `(pubsub_server, topic, event, payload)` and dispatches
    # on topic directly — no Socket required, no need to track the
    # channel pid at all.
    with true <- state.account_id != nil,
         :ok <-
           Phoenix.Channel.Server.broadcast!(
             MealPlannerApi.PubSub,
             "planning:#{state.account_id}",
             event,
             payload
           ) do
      :ok
    else
      _ -> :ok
    end
  end

  defp fetch_proposal(id) do
    Repo.get!(MealPlannerApi.Persistence.Planning.PlanningProposal, id)
  end

  defp fetch_proposal_with_run(proposal_id) do
    proposal = fetch_proposal(proposal_id)

    run =
      Repo.get!(
        MealPlannerApi.Persistence.Planning.PlanningGenerationRun,
        proposal.generation_run_id
      )

    {:ok, proposal, run}
  end

  defp verify_ownership(proposal_id, account_id) do
    case fetch_proposal_with_run(proposal_id) do
      {:ok, _proposal, run} ->
        if run.account_id == account_id, do: :ok, else: {:error, :forbidden}
    end
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
  end

  defp persist_scheduled_meals(proposal, state) do
    slots = get_in(proposal.proposal_json, [:slots]) || []
    slots = if slots == [], do: get_in(proposal.proposal_json, ["slots"]) || [], else: slots

    result =
      Enum.reduce_while(slots, [], fn slot, acc ->
        [date, slot_name] = split_slot_key(slot)

        attrs = %{
          account_id: state.account_id,
          user_id: state.user_id,
          generation_run_id: proposal.generation_run_id,
          planning_proposal_id: proposal.id,
          date: Date.from_iso8601!(date),
          slot: String.to_existing_atom(slot_name),
          recipe_id: parse_recipe_id(Map.get(slot, :recipe_id) || Map.get(slot, "recipe_id")),
          is_cooked: false
        }

        case PlanningRepo.schedule_meal(attrs) do
          {:ok, meal} -> {:cont, [meal | acc]}
          {:error, _} = err -> {:halt, err}
        end
      end)

    case result do
      {:error, _} = err -> err
      meals -> {:ok, Enum.reverse(meals)}
    end
  end

  # `build_proposal_json/1` writes slots with atom keys (`slot_key:`,
  # `recipe_id:`); legacy callers / tests may store string keys. Accept
  # both shapes so the existing on-wire proposal format (atom-keyed from
  # `build_proposal_json`) and the same shape expressed as a string map
  # both flow through the confirm pipeline.
  defp split_slot_key(%{slot_key: sk}) when is_binary(sk), do: String.split(sk, "_", parts: 2)
  defp split_slot_key(%{"slot_key" => sk}) when is_binary(sk), do: String.split(sk, "_", parts: 2)

  # Will fail loudly in `Date.from_iso8601!/1` / `String.to_existing_atom/1` rather than silently filter.
  defp split_slot_key(_), do: [nil, nil]

  # Builds and persists the shopping cart derived from the confirmed
  # scheduled meals. Pure-Elixir aggregation inside the same `Repo.transaction`
  # as `persist_scheduled_meals/2` (planning-shopping-extraction design §4).
  #
  # Returns `{:ok, %{cart, lines_count, checkout_session_id}}` so the
  # caller can surface the deduped summary, the persisted row count, and the
  # session id back to the client.
  defp persist_shopping_cart(scheduled_meals, state) do
    recipe_ids =
      scheduled_meals
      |> Enum.map(& &1.recipe_id)
      |> Enum.reject(&is_nil/1)

    by_recipe = RecipeRepo.list_ingredients_for_recipes(recipe_ids)

    lines = GenerationService.build_cart_lines(scheduled_meals, by_recipe)

    with {:ok, session} <-
           ShoppingRepo.create_checkout_session(%{
             account_id: state.account_id,
             status: :draft,
             checkout_type: :physical
           }),
         :ok <- insert_cart_items(lines, state.account_id, session.id) do
      {:ok,
       %{
         cart: GenerationService.summarize_cart(lines),
         lines_count: length(lines),
         checkout_session_id: session.id
       }}
    end
  end

  defp insert_cart_items(lines, account_id, session_id) do
    Enum.reduce_while(lines, :ok, fn line, :ok ->
      attrs = %{
        account_id: account_id,
        scheduled_meal_id: line.scheduled_meal_id,
        planned_date: line.planned_date,
        ingredient_id: line.ingredient_id,
        unit: line.unit,
        quantity_milli: line.quantity_milli,
        checkout_session_id: session_id,
        status: :pending
      }

      case ShoppingRepo.create_shopping_item(attrs) do
        {:ok, _} -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
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

  defp parse_recipe_id(nil), do: nil
  defp parse_recipe_id(id) when is_integer(id), do: id

  defp parse_recipe_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> int
      _ -> id
    end
  end

  defp parse_recipe_id(_), do: nil
end
