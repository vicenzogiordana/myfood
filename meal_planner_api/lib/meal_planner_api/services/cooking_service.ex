defmodule MealPlannerApi.Services.CookingService do
  @moduledoc """
  Runtime cooking orchestration with contextual AI assistant.

  Coordinates:
  - Session lifecycle (start, state, finish)
  - Step tracking with snapshot persistence
  - Chat messages with contextual AI answers
  - Inventory deduction on session completion

  Stateless service — all DB via PlanningRepo and InventoryRepo.
  """

  alias MealPlannerApi.AI
  alias MealPlannerApi.Data.{InventoryRepo, PlanningRepo}
  alias MealPlannerApi.Persistence.Identity
  alias MealPlannerApi.Persistence.Planning

  @type step_status :: :started | :paused | :completed | :error

  # -------------------------------------------------------------------------
  # Session lifecycle
  # -------------------------------------------------------------------------

  @spec start_session(map(), binary()) :: {:ok, map()} | {:error, term()}
  def start_session(current_user, scheduled_meal_id) when is_binary(scheduled_meal_id) do
    with {:ok, ids} <- Identity.ensure_persistent_identity(current_user),
         meal when not is_nil(meal) <-
           PlanningRepo.get_scheduled_meal_for_account(ids.account_id, scheduled_meal_id),
         {:ok, session} <- create_session(ids, meal) do
      snapshot = PlanningRepo.latest_context_snapshot(session.id)
      # Preload scheduled_meal on session for serialization
      session = PlanningRepo.get_cooking_session_for_account(ids.account_id, session.id)
      {:ok, serialize_session_payload(session, snapshot)}
    else
      nil -> {:error, :scheduled_meal_not_found}
      {:error, _} = error -> error
    end
  end

  @spec session_state(map(), binary()) :: {:ok, map()} | {:error, term()}
  def session_state(current_user, session_id) when is_binary(session_id) do
    with {:ok, ids} <- Identity.ensure_persistent_identity(current_user),
         session when not is_nil(session) <-
           PlanningRepo.get_cooking_session_for_account(ids.account_id, session_id) do
      snapshot = PlanningRepo.latest_context_snapshot(session.id)
      {:ok, serialize_session_payload(session, snapshot)}
    else
      nil -> {:error, :session_not_found}
      {:error, _} = error -> error
    end
  end

  @spec finish_session(map(), binary()) :: {:ok, map()} | {:error, term()}
  def finish_session(current_user, session_id) when is_binary(session_id) do
    with {:ok, ids} <- Identity.ensure_persistent_identity(current_user),
         session when not is_nil(session) <-
           PlanningRepo.get_cooking_session_for_account(ids.account_id, session_id),
         {:ok, result} <- persist_finish(ids, session) do
      {:ok,
       %{
         session_id: session.id,
         scheduled_meal_id: session.scheduled_meal_id,
         status: "completed",
         inventory_mutations: result.inventory_mutations
       }}
    else
      nil -> {:error, :session_not_found}
      {:error, _} = error -> error
    end
  end

  # -------------------------------------------------------------------------
  # Step tracking
  # -------------------------------------------------------------------------

  @spec track_step(map(), binary(), binary(), step_status(), map()) ::
          {:ok, map()} | {:error, term()}
  def track_step(current_user, session_id, recipe_step_id, status, extra \\ %{})
      when is_binary(session_id) and is_binary(recipe_step_id) and
             status in [:started, :paused, :completed, :error] do
    with {:ok, ids} <- Identity.ensure_persistent_identity(current_user),
         session when not is_nil(session) <-
           PlanningRepo.get_cooking_session_for_account(ids.account_id, session_id),
         true <- belongs_to_recipe?(session, recipe_step_id),
         {:ok, event} <-
           PlanningRepo.add_step_event(%{
             cooking_session_id: session.id,
             recipe_step_id: recipe_step_id,
             event_type: status,
             event_at: DateTime.utc_now()
           }),
         snapshot_data <- build_snapshot_data(session, recipe_step_id, status, extra),
         {:ok, snapshot} <-
           PlanningRepo.add_context_snapshot(%{
             cooking_session_id: session.id,
             snapshot_data: snapshot_data,
             captured_at: DateTime.utc_now()
           }) do
      {:ok,
       %{
         session_id: session.id,
         recipe_step_id: recipe_step_id,
         status: Atom.to_string(event.event_type),
         snapshot: snapshot.snapshot_data
       }}
    else
      nil -> {:error, :session_not_found}
      false -> {:error, :recipe_step_not_found}
      {:error, _} = error -> error
    end
  end

  # -------------------------------------------------------------------------
  # Chat / AI answers
  # -------------------------------------------------------------------------

  @spec answer_question(map(), binary(), binary(), String.t()) :: {:ok, map()} | {:error, term()}
  def answer_question(current_user, session_id, message, content_type \\ "text")
      when is_binary(session_id) and is_binary(message) and is_binary(content_type) do
    with {:ok, ids} <- Identity.ensure_persistent_identity(current_user),
         session when not is_nil(session) <-
           PlanningRepo.get_cooking_session_for_account(ids.account_id, session_id),
         {:ok, _user_msg} <-
           PlanningRepo.add_chat_message(%{
             cooking_session_id: session.id,
             user_id: ids.user_id,
             role: :user,
             content: message
           }),
         current_snapshot <- PlanningRepo.latest_context_snapshot(session.id),
         assistant_text <-
           build_contextual_answer(session, current_snapshot, message, content_type),
         {:ok, _assistant_msg} <-
           PlanningRepo.add_chat_message(%{
             cooking_session_id: session.id,
             role: :assistant,
             content: assistant_text
           }) do
      {:ok,
       %{
         session_id: session.id,
         message: assistant_text,
         content_type: "text",
         step_context: snapshot_step_context(current_snapshot)
       }}
    else
      nil -> {:error, :session_not_found}
      {:error, _} = error -> error
    end
  end

  # -------------------------------------------------------------------------
  # Private helpers
  # -------------------------------------------------------------------------

  defp create_session(ids, meal) do
    recipe = meal.recipe

    first_step_id =
      recipe &&
        recipe.recipe_steps
        |> Enum.sort_by(& &1.step_number)
        |> List.first()
        |> case do
          nil -> nil
          step -> step.id
        end

    initial_snapshot = %{
      "current_step_id" => first_step_id,
      "step_status" => "started",
      "timers" => %{},
      "view" => "recipe"
    }

    result =
      Planning.create_cooking_session(%{
        account_id: ids.account_id,
        scheduled_meal_id: meal.id,
        status: :active,
        started_at: DateTime.utc_now(),
        context_snapshot: initial_snapshot
      })

    with {:ok, session} <- result do
      # Capture the initial context snapshot
      {:ok, _snapshot} =
        PlanningRepo.add_context_snapshot(%{
          cooking_session_id: session.id,
          snapshot_data: initial_snapshot,
          captured_at: DateTime.utc_now()
        })

      # Record the first step event if a step exists
      if first_step_id do
        {:ok, _event} =
          PlanningRepo.add_step_event(%{
            cooking_session_id: session.id,
            recipe_step_id: first_step_id,
            event_type: :started,
            event_at: DateTime.utc_now()
          })
      end

      {:ok, session}
    else
      {:error, _} = error -> error
    end
  end

  defp persist_finish(ids, session) do
    recipe_ingredients =
      (session.scheduled_meal &&
         session.scheduled_meal.recipe &&
         session.scheduled_meal.recipe.recipe_ingredients) ||
        []

    # Mark session and scheduled meal as completed
    session_data =
      PlanningRepo.get_cooking_session!(session.id)

    # Update session status
    session_data
    |> Ecto.Changeset.change(%{status: :completed, completed_at: DateTime.utc_now()})
    |> MealPlannerApi.Repo.update()

    # Update scheduled meal is_cooked flag
    if session.scheduled_meal do
      session.scheduled_meal
      |> Ecto.Changeset.change(%{is_cooked: true})
      |> MealPlannerApi.Repo.update()
    end

    # Apply inventory deductions for all recipe ingredients
    mutation_results =
      Enum.map(recipe_ingredients, fn ingredient ->
        InventoryRepo.apply_delta(%{
          account_id: ids.account_id,
          ingredient_id: ingredient.ingredient_id,
          unit: ingredient.unit,
          source_kind: :planned,
          delta: -ingredient.quantity_milli,
          source_user_id: ids.user_id,
          source_cooking_session_id: session.id,
          trigger_type: :cooking,
          operation: :subtract,
          metadata: %{scheduled_meal_id: session.scheduled_meal_id}
        })
      end)

    success_count = Enum.count(mutation_results, &match?({:ok, _}, &1))

    if Enum.any?(mutation_results, &match?({:error, _}, &1)) do
      {:error, :inventory_mutation_failed}
    else
      {:ok, %{inventory_mutations: success_count}}
    end
  end

  defp belongs_to_recipe?(session, recipe_step_id) do
    (session.scheduled_meal &&
       session.scheduled_meal.recipe &&
       session.scheduled_meal.recipe.recipe_steps &&
       Enum.any?(session.scheduled_meal.recipe.recipe_steps, &(&1.id == recipe_step_id))) ||
      false
  end

  defp build_snapshot_data(session, recipe_step_id, status, extra) do
    previous = session.context_snapshot || %{}

    previous
    |> Map.merge(%{
      "current_step_id" => recipe_step_id,
      "step_status" => Atom.to_string(status),
      "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    })
    |> maybe_put("timers", extra["timers"])
    |> maybe_put("view", extra["view"])
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp build_contextual_answer(session, snapshot, question, content_type) do
    recipe = session.scheduled_meal && session.scheduled_meal.recipe

    step_text =
      if recipe do
        current_step_id = snapshot_step_context(snapshot)
        step = Enum.find(recipe.recipe_steps, &(&1.id == current_step_id))

        if step do
          "Paso actual #{step.step_number}: #{step.instructions}."
        else
          "No tengo paso activo, te guio con la receta completa."
        end
      else
        "Tenes una sesion de cocina activa."
      end

    system_prompt = build_system_prompt(recipe, step_text, content_type)

    case AI.generate_text(question, system_prompt: system_prompt) do
      {:ok, text} ->
        text

      {:error, _reason} ->
        fallback_answer(question, content_type, recipe && recipe.name, step_text)
    end
  end

  defp build_system_prompt(recipe, step_text, content_type) do
    voice_mode = if content_type == "speech_transcript", do: "si", else: "no"
    recipe_name = (recipe && recipe.name) || "receta sin nombre"

    steps_text =
      if recipe && recipe.recipe_steps do
        recipe.recipe_steps
        |> Enum.sort_by(& &1.step_number)
        |> Enum.map(fn step -> "#{step.step_number}. #{step.instructions}" end)
        |> Enum.join("\n")
      else
        "Sin pasos disponibles"
      end

    ingredients_text =
      if recipe && recipe.recipe_ingredients do
        recipe.recipe_ingredients
        |> Enum.map(fn ri ->
          name = (ri.ingredient && ri.ingredient.name) || "ingrediente"
          "- #{name}: #{ri.quantity_milli} #{ri.unit}"
        end)
        |> Enum.join("\n")
      else
        "Sin ingredientes disponibles"
      end

    """
    Eres el asistente culinario de MyFood.
    El usuario esta cocinando la receta: #{recipe_name}.
    Modo voz: #{voice_mode}.
    #{step_text}

    Ingredientes de la receta:
    #{ingredients_text}

    Pasos oficiales de la receta:
    #{steps_text}

    Responde basandote estrictamente en esta receta.
    Da una respuesta breve, accionable y segura para cocina.
    Si falta informacion, dilo sin inventar.
    """
  end

  defp fallback_answer(question, content_type, recipe_name, step_text) do
    prefix = if content_type == "speech_transcript", do: "Entendido por voz", else: "Entendido"
    name = recipe_name || "una receta"

    "#{prefix}. Estas cocinando #{name}. #{step_text} #{brief_guidance(question)}"
  end

  defp brief_guidance(question) do
    lowered = String.downcase(question)

    cond do
      String.contains?(lowered, "salsa") ->
        "Manten fuego bajo a medio y agrega liquido de a poco para que no se pegue."

      String.contains?(lowered, "sal") ->
        "Agrega sal gradualmente, mezcla y prueba antes de corregir otra vez."

      String.contains?(lowered, "quemado") or String.contains?(lowered, "pegado") ->
        "Retira lo que puedas, raspá el fondo y agregá liquido. Revolvé constantemente."

      true ->
        "Segui el paso actual y ajustá de a una variable: fuego, liquido o tiempo."
    end
  end

  defp snapshot_step_context(nil), do: nil

  defp snapshot_step_context(snapshot) do
    (snapshot && snapshot.snapshot_data && snapshot.snapshot_data["current_step_id"]) ||
      (snapshot && snapshot.snapshot_data && snapshot.snapshot_data["current_step_id"]) ||
      nil
  end

  # -------------------------------------------------------------------------
  # Serialization
  # -------------------------------------------------------------------------

  defp serialize_session_payload(session, latest_snapshot) do
    scheduled_meal =
      case session.scheduled_meal do
        %Ecto.Association.NotLoaded{} -> nil
        sm -> sm
      end

    recipe =
      scheduled_meal &&
        case scheduled_meal.recipe do
          %Ecto.Association.NotLoaded{} -> nil
          r -> r
        end

    %{
      session_id: session.id,
      scheduled_meal_id: session.scheduled_meal_id,
      status: Atom.to_string(session.status),
      slot:
        (scheduled_meal &&
           case scheduled_meal.slot do
             nil -> "unknown"
             atom when is_atom(atom) -> Atom.to_string(atom)
             string when is_binary(string) -> string
             _ -> "unknown"
           end) || "unknown",
      recipe:
        if recipe do
          %{
            id: recipe.id,
            name: recipe.name,
            steps: serialize_steps(recipe.recipe_steps),
            ingredients: serialize_ingredients(recipe.recipe_ingredients)
          }
        else
          %{id: nil, name: nil, steps: [], ingredients: []}
        end,
      snapshot:
        (latest_snapshot && latest_snapshot.snapshot_data) ||
          session.context_snapshot ||
          %{},
      chat_messages:
        (session.chat_messages &&
           not is_struct(session.chat_messages, Ecto.Association.NotLoaded) &&
           Enum.map(session.chat_messages, &serialize_chat/1)) || []
    }
  end

  defp serialize_steps(nil), do: []
  defp serialize_steps(%Ecto.Association.NotLoaded{}), do: []

  defp serialize_steps(steps) do
    steps
    |> Enum.sort_by(& &1.step_number)
    |> Enum.map(fn step ->
      %{
        id: step.id,
        step_number: step.step_number,
        instructions: step.instructions,
        duration_minutes: step.duration_minutes
      }
    end)
  end

  defp serialize_ingredients(nil), do: []
  defp serialize_ingredients(%Ecto.Association.NotLoaded{}), do: []

  defp serialize_ingredients(ingredients) do
    Enum.map(ingredients, fn item ->
      %{
        ingredient_id: item.ingredient_id,
        name: item.ingredient && item.ingredient.name,
        quantity_milli: item.quantity_milli,
        unit: Atom.to_string(item.unit)
      }
    end)
  end

  defp serialize_chat(msg) do
    %{
      id: msg.id,
      role: Atom.to_string(msg.role),
      content: msg.content,
      inserted_at: msg.inserted_at
    }
  end
end
