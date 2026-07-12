defmodule MealPlannerApiWeb.CookingController do
  use MealPlannerApiWeb, :controller

  alias MealPlannerApi.Services.CookingService
  alias MealPlannerApiWeb.Controllers.AccountScopeHelpers

  # Phase A — Tenancy Refactor (PR 3c task 3.16): tenancy scope is always
  # resolved from `conn.assigns.current_membership.account_id`, never
  # from the legacy `current_user.account_id` field. See
  # `AccountScopeHelpers.scope_user_to_membership/2`.

  def start(conn, %{"scheduled_meal_id" => scheduled_meal_id}) do
    user = scoped_user(conn)

    case CookingService.start_session(user, scheduled_meal_id) do
      {:ok, session} ->
        json(conn, %{data: session})

      {:error, reason} ->
        conn
        |> put_status(error_status(reason))
        |> json(%{error: reason})
    end
  end

  def show(conn, %{"session_id" => session_id}) do
    user = scoped_user(conn)

    case CookingService.session_state(user, session_id) do
      {:ok, state} ->
        json(conn, %{data: state})

      {:error, reason} ->
        conn
        |> put_status(error_status(reason))
        |> json(%{error: reason})
    end
  end

  def step(conn, %{"session_id" => session_id, "recipe_step_id" => step_id} = params) do
    user = scoped_user(conn)

    status =
      case params["status"] do
        "started" -> :started
        "paused" -> :paused
        "completed" -> :completed
        "error" -> :error
        _ -> :started
      end

    extra = Map.drop(params, ["session_id", "recipe_step_id", "status"])

    case CookingService.track_step(user, session_id, step_id, status, extra) do
      {:ok, result} ->
        json(conn, %{data: result})

      {:error, reason} ->
        conn
        |> put_status(error_status(reason))
        |> json(%{error: reason})
    end
  end

  def step(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: :missing_fields})
  end

  def finish(conn, %{"session_id" => session_id}) do
    user = scoped_user(conn)

    case CookingService.finish_session(user, session_id) do
      {:ok, result} ->
        json(conn, %{data: result})

      {:error, reason} ->
        conn
        |> put_status(error_status(reason))
        |> json(%{error: reason})
    end
  end

  def ask(conn, %{"session_id" => session_id, "message" => message} = params) do
    user = scoped_user(conn)
    content_type = Map.get(params, "content_type", "text")

    case CookingService.answer_question(user, session_id, message, content_type) do
      {:ok, result} ->
        json(conn, %{data: result})

      {:error, reason} ->
        conn
        |> put_status(error_status(reason))
        |> json(%{error: reason})
    end
  end

  def ask(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: :missing_fields})
  end

  # -------------------------------------------------------------------------
  # Private helpers
  # -------------------------------------------------------------------------

  defp scoped_user(conn) do
    conn
    |> Guardian.Plug.current_resource()
    |> AccountScopeHelpers.scope_user_to_membership(conn.assigns.current_membership)
  end

  defp error_status(:scheduled_meal_not_found), do: :not_found
  defp error_status(:session_not_found), do: :not_found
  defp error_status(:recipe_step_not_found), do: :not_found
  defp error_status(:inventory_mutation_failed), do: :unprocessable_entity
  defp error_status(_), do: :internal_server_error
end
