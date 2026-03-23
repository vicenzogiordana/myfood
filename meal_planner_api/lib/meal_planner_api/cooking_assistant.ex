defmodule MealPlannerApi.CookingAssistant do
  @moduledoc """
  Runtime cooking orchestration with contextual assistant and inventory impact.
  """

  alias Ecto.Multi
  alias MealPlannerApi.AI
  alias MealPlannerApi.Persistence.Identity
  alias MealPlannerApi.Persistence.Inventory
  alias MealPlannerApi.Persistence.Planning
  alias MealPlannerApi.Repo

  @type step_status :: :started | :paused | :completed | :error

  @spec start_session(map(), binary()) :: {:ok, map()} | {:error, term()}
  def start_session(current_user, scheduled_meal_id) when is_binary(scheduled_meal_id) do
    with {:ok, ids} <- Identity.ensure_persistent_identity(current_user),
         meal when not is_nil(meal) <-
           Planning.get_scheduled_meal_for_account(ids.account_id, scheduled_meal_id),
         {:ok, result} <- persist_start(ids, meal),
         session when not is_nil(session) <-
           Planning.get_cooking_session_for_account(ids.account_id, result.session.id) do
      {:ok, serialize_session_payload(session, result.snapshot)}
    else
      nil -> {:error, :scheduled_meal_not_found}
      {:error, _} = error -> error
    end
  end

  @spec session_state(map(), binary()) :: {:ok, map()} | {:error, term()}
  def session_state(current_user, session_id) when is_binary(session_id) do
    with {:ok, ids} <- Identity.ensure_persistent_identity(current_user),
         session when not is_nil(session) <-
           Planning.get_cooking_session_for_account(ids.account_id, session_id) do
      latest_snapshot =
        session.context_snapshots
        |> Enum.sort_by(& &1.captured_at, {:desc, DateTime})
        |> List.first()

      {:ok, serialize_session_payload(session, latest_snapshot)}
    else
      nil -> {:error, :session_not_found}
      {:error, _} = error -> error
    end
  end

  @spec track_step(map(), binary(), binary(), step_status(), map()) ::
          {:ok, map()} | {:error, term()}
  def track_step(current_user, session_id, recipe_step_id, status, extra \\ %{})
      when is_binary(session_id) and is_binary(recipe_step_id) and
             status in [:started, :paused, :completed, :error] do
    with {:ok, ids} <- Identity.ensure_persistent_identity(current_user),
         session when not is_nil(session) <-
           Planning.get_cooking_session_for_account(ids.account_id, session_id),
         true <- belongs_to_recipe?(session, recipe_step_id),
         {:ok, event} <-
           Planning.add_step_event(%{
             cooking_session_id: session.id,
             recipe_step_id: recipe_step_id,
             event_type: status,
             event_at: DateTime.utc_now()
           }),
         snapshot_data <- build_snapshot_data(session, recipe_step_id, status, extra),
         {:ok, snapshot} <-
           Planning.add_context_snapshot(%{
             cooking_session_id: session.id,
             snapshot_data: snapshot_data,
             captured_at: DateTime.utc_now()
           }),
         {:ok, _updated} <-
           Planning.update_cooking_session(session, %{context_snapshot: snapshot_data}) do
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

  @spec answer_question(map(), binary(), binary(), String.t()) :: {:ok, map()} | {:error, term()}
  def answer_question(current_user, session_id, message, content_type \\ "text")
      when is_binary(session_id) and is_binary(message) and is_binary(content_type) do
    with {:ok, ids} <- Identity.ensure_persistent_identity(current_user),
         session when not is_nil(session) <-
           Planning.get_cooking_session_for_account(ids.account_id, session_id),
         {:ok, _user_msg} <-
           Planning.add_cooking_message(%{
             cooking_session_id: session.id,
             user_id: ids.user_id,
             role: :user,
             content: message
           }),
         current_snapshot <- Planning.latest_context_snapshot(session.id),
         assistant_text <-
           build_contextual_answer(session, current_snapshot, message, content_type),
         {:ok, _assistant_msg} <-
           Planning.add_cooking_message(%{
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

  @spec finish_session(map(), binary()) :: {:ok, map()} | {:error, term()}
  def finish_session(current_user, session_id) when is_binary(session_id) do
    with {:ok, ids} <- Identity.ensure_persistent_identity(current_user),
         session when not is_nil(session) <-
           Planning.get_cooking_session_for_account(ids.account_id, session_id),
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

  defp persist_start(ids, meal) do
    first_step_id =
      meal.recipe &&
        meal.recipe.recipe_steps
        |> Enum.sort_by(& &1.step_number)
        |> List.first()
        |> maybe_step_id()

    initial_snapshot = %{
      current_step_id: first_step_id,
      step_status: "started",
      timers: %{},
      view: "recipe"
    }

    Multi.new()
    |> Multi.insert(
      :session,
      MealPlannerApi.Persistence.Planning.CookingSession.changeset(
        %MealPlannerApi.Persistence.Planning.CookingSession{},
        %{
          account_id: ids.account_id,
          scheduled_meal_id: meal.id,
          status: :active,
          started_at: DateTime.utc_now(),
          context_snapshot: initial_snapshot
        }
      )
    )
    |> Multi.run(:snapshot, fn _repo, %{session: session} ->
      Planning.add_context_snapshot(%{
        cooking_session_id: session.id,
        snapshot_data: initial_snapshot,
        captured_at: DateTime.utc_now()
      })
    end)
    |> Multi.run(:first_step_event, fn _repo, %{session: session} ->
      if is_binary(first_step_id) do
        Planning.add_step_event(%{
          cooking_session_id: session.id,
          recipe_step_id: first_step_id,
          event_type: :started,
          event_at: DateTime.utc_now()
        })
      else
        {:ok, nil}
      end
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{session: session, snapshot: snapshot}} ->
        {:ok, %{session: session, snapshot: snapshot}}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  defp persist_finish(ids, session) do
    recipe_ingredients = session.scheduled_meal.recipe.recipe_ingredients

    Multi.new()
    |> Multi.update(
      :session,
      MealPlannerApi.Persistence.Planning.CookingSession.changeset(session, %{
        status: :completed,
        completed_at: DateTime.utc_now()
      })
    )
    |> Multi.update(
      :scheduled_meal,
      MealPlannerApi.Persistence.Planning.ScheduledMeal.changeset(session.scheduled_meal, %{
        is_cooked: true
      })
    )
    |> Multi.run(:inventory_mutations, fn _repo, _changes ->
      mutation_results =
        Enum.map(recipe_ingredients, fn ingredient ->
          Inventory.apply_delta_and_log(%{
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

      if Enum.all?(mutation_results, &match?({:ok, _}, &1)) do
        {:ok, length(mutation_results)}
      else
        {:error, :inventory_mutation_failed}
      end
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{inventory_mutations: count}} -> {:ok, %{inventory_mutations: count}}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  defp belongs_to_recipe?(session, recipe_step_id) do
    session.scheduled_meal.recipe.recipe_steps
    |> Enum.any?(&(&1.id == recipe_step_id))
  end

  defp build_snapshot_data(session, recipe_step_id, status, extra) do
    previous_snapshot = session.context_snapshot || %{}

    previous_snapshot
    |> Map.merge(%{
      "current_step_id" => recipe_step_id,
      "step_status" => Atom.to_string(status),
      "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    })
    |> maybe_put_timers(extra)
    |> maybe_put_view(extra)
  end

  defp maybe_put_timers(snapshot, extra) do
    case Map.get(extra, "timers") do
      timers when is_map(timers) -> Map.put(snapshot, "timers", timers)
      _ -> snapshot
    end
  end

  defp maybe_put_view(snapshot, extra) do
    case Map.get(extra, "view") do
      view when is_binary(view) -> Map.put(snapshot, "view", view)
      _ -> snapshot
    end
  end

  defp build_contextual_answer(session, snapshot, question, content_type) do
    recipe = session.scheduled_meal.recipe
    step_text = current_step_text(recipe, snapshot)
    system_prompt = build_system_prompt(recipe, step_text, content_type)

    case AI.generate_text(question, system_prompt: system_prompt) do
      {:ok, text} ->
        text

      {:error, _reason} ->
        fallback_contextual_answer(question, content_type, recipe.name, step_text)
    end
  end

  defp current_step_text(recipe, snapshot) do
    current_step_id = snapshot_step_context(snapshot)

    step = Enum.find(recipe.recipe_steps, &(&1.id == current_step_id))

    if step do
      "Paso actual #{step.step_number}: #{step.instructions}."
    else
      "No tengo paso activo, te guio con la receta completa."
    end
  end

  defp brief_guidance(question) do
    cond do
      String.contains?(String.downcase(question), "salsa") ->
        "Manten fuego bajo a medio y ajusta con liquido de a poco para que no se pegue."

      String.contains?(String.downcase(question), "sal") ->
        "Si te olvidaste, agrega sal gradualmente, mezcla y prueba antes de corregir otra vez."

      true ->
        "Segui el paso actual y corrige de a una variable: fuego, liquido o tiempo."
    end
  end

  defp build_system_prompt(recipe, step_text, content_type) do
    steps_text =
      recipe.recipe_steps
      |> Enum.sort_by(& &1.step_number)
      |> Enum.map(fn step -> "#{step.step_number}. #{step.instructions}" end)
      |> Enum.join("\n")

    ingredients_text =
      recipe.recipe_ingredients
      |> Enum.map(fn ri ->
        ingredient_name = if ri.ingredient, do: ri.ingredient.name, else: "ingrediente"
        "- #{ingredient_name}: #{ri.quantity_milli} #{ri.unit}"
      end)
      |> Enum.join("\n")

    voice_mode = if content_type == "speech_transcript", do: "si", else: "no"

    """
    Eres el asistente culinario de MyFood.
    El usuario esta cocinando la receta: #{recipe.name}.
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

  defp fallback_contextual_answer(question, content_type, recipe_name, step_text) do
    prefix = if content_type == "speech_transcript", do: "Entendido por voz", else: "Entendido"

    "#{prefix}. Estas cocinando #{recipe_name}. #{step_text} Respuesta: #{brief_guidance(question)}"
  end

  defp maybe_step_id(nil), do: nil
  defp maybe_step_id(step), do: step.id

  defp snapshot_step_context(nil), do: nil

  defp snapshot_step_context(snapshot),
    do:
      Map.get(snapshot.snapshot_data || snapshot, "current_step_id") ||
        Map.get(snapshot.snapshot_data || snapshot, :current_step_id)

  defp serialize_session_payload(session, latest_snapshot) do
    recipe = session.scheduled_meal.recipe

    %{
      session_id: session.id,
      scheduled_meal_id: session.scheduled_meal_id,
      status: Atom.to_string(session.status),
      slot: Atom.to_string(session.scheduled_meal.slot),
      recipe: %{
        id: recipe.id,
        name: recipe.name,
        steps: serialize_steps(recipe.recipe_steps),
        ingredients: serialize_ingredients(recipe.recipe_ingredients)
      },
      snapshot: latest_snapshot && latest_snapshot.snapshot_data,
      chat_messages: Enum.map(session.chat_messages || [], &serialize_chat/1)
    }
  end

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
