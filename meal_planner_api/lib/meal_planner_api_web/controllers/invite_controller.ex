defmodule MealPlannerApiWeb.InviteController do
  @moduledoc """
  Owner-invites-member + invitee-accepts flows (Phase A — Tenancy
  Refactor, PR 3a tasks 3.3 / 3.4). See `specs/invite-and-accept.md`.
  """

  use MealPlannerApiWeb, :controller

  alias MealPlannerApi.AccountsMembership
  alias MealPlannerApi.Auth.Guardian
  alias MealPlannerApiWeb.Controllers.AccountScopeHelpers

  @doc """
  `POST /api/accounts/:account_id/invites` — owner-only. Body:
  `{"email": "..."}`. Returns `201 {invite: {token, expires_at,
  membership_id, email}}`. Errors per spec §6.1: `403 not_owner`,
  `409 seat_cap_reached`, `409 already_invited`, `409 already_a_member`.
  """
  def create(conn, %{"account_id" => account_id, "email" => email}) do
    actor = conn.assigns.current_membership

    with {:ok, account} <- AccountScopeHelpers.load_account(account_id),
         {:ok, result} <- AccountsMembership.invite(account, actor, email) do
      conn
      |> put_status(:created)
      |> json(%{
        invite: %{
          token: result.token,
          expires_at: result.expires_at,
          membership_id: result.membership_id,
          email: result.email
        }
      })
    else
      {:error, :account_not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "account_not_found"})

      {:error, reason} ->
        conn |> put_status(error_status(reason)) |> json(%{error: Atom.to_string(reason)})
    end
  end

  @doc """
  `POST /api/invites/:token/accept` — body `{}` for an existing User
  (identified via an optional `Authorization` header — this route is
  deliberately NOT behind the `:auth` pipeline because the "new User"
  case has no account/token yet, per `specs/invite-and-accept.md`
  §"New User accepts") or `{"name": ..., "password": ...}` for a brand
  new User. Errors: `401 unauthorized` (no body params and no valid
  Bearer token), `410 invite_token_used`, `410 invite_token_expired`.
  """
  def accept(conn, %{"token" => token} = params) do
    case resolve_invitee(conn, params) do
      {:ok, invitee_arg} ->
        case AccountsMembership.accept_invite(token, invitee_arg) do
          {:ok, %{user: user, account: account, membership: membership, claims: claims}} ->
            AccountScopeHelpers.render_membership_auth_response(
              conn,
              user,
              account,
              membership,
              claims
            )

          {:error, reason} ->
            conn |> put_status(error_status(reason)) |> json(%{error: Atom.to_string(reason)})
        end

      :unauthenticated ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "unauthorized"})
    end
  end

  # New User path: {"name": ..., "password": ...} needs no prior auth —
  # the invitee has no account/token yet.
  defp resolve_invitee(_conn, %{"name" => name, "password" => password})
       when is_binary(name) and name != "" and is_binary(password) and password != "" do
    {:ok, %{name: name, password_hash: Bcrypt.hash_pwd_salt(password)}}
  end

  # Existing User path: body is `{}` — identify the caller via an
  # optional Authorization header (manual decode, NOT the `:auth`
  # pipeline, since this route must also serve unauthenticated new
  # Users).
  defp resolve_invitee(conn, _params) do
    with [header] <- Plug.Conn.get_req_header(conn, "authorization"),
         "Bearer " <> raw_token <- header,
         {:ok, claims} <- Guardian.decode_and_verify(raw_token),
         {:ok, user} <- Guardian.resource_from_claims(claims) do
      {:ok, user}
    else
      _ -> :unauthenticated
    end
  end

  defp error_status(:not_owner), do: :forbidden
  defp error_status(:seat_cap_reached), do: :conflict
  defp error_status(:already_invited), do: :conflict
  defp error_status(:already_a_member), do: :conflict
  defp error_status(:invite_token_used), do: :gone
  defp error_status(:invite_token_expired), do: :gone
  defp error_status(:invite_token_unknown), do: :not_found
  defp error_status(:invalid_invitee), do: :bad_request
  defp error_status(_), do: :unprocessable_entity
end
