defmodule MealPlannerApiWeb.Plugs.OptionalBearerUser do
  @moduledoc """
  Phase 2 — Verification and Lockout (issue #31 task 2.4).

  Optional bearer decoder used by `POST /api/auth/email-code/verify`.

  Behavior:

    * **No header** → assigns nothing. The passwordless flow — the
      controller forwards `principal: nil` to
      `MealPlannerApi.Services.EmailCodeAuth.verify_code/3`.
    * **Header present + valid** → assigns `:optional_current_user_id`
      with the decoded JWT subject. The controller forwards
      `principal: <user_id>` to the service.
    * **Header present + invalid** → halts with `401 invalid_bearer` and
      a JSON body. The service is never called.

  The plug deliberately does NOT load the full `%User{}` row — the
  verify service only needs the resolved `user_id` for principal
  binding. Loading the user belongs to the consuming layer (Phase 3
  will need it for the membership outcome).
  """

  @behaviour Plug

  alias MealPlannerApi.Auth.Guardian
  alias Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case Conn.get_req_header(conn, "authorization") do
      [] ->
        conn

      [header | _] ->
        decode_authorization(conn, header)
    end
  end

  defp decode_authorization(conn, header) do
    case String.split(header, " ", parts: 2) do
      ["Bearer", token] when is_binary(token) and byte_size(token) > 0 ->
        case Guardian.decode_and_verify(token) do
          {:ok, %{"sub" => user_id}} when is_binary(user_id) ->
            Conn.assign(conn, :optional_current_user_id, user_id)

          {:ok, _claims} ->
            # No `sub` claim means Guardian couldn't load a resource;
            # treat the same as an unparseable bearer.
            halt_invalid_bearer(conn)

          {:error, _reason} ->
            halt_invalid_bearer(conn)
        end

      _ ->
        halt_invalid_bearer(conn)
    end
  end

  defp halt_invalid_bearer(conn) do
    conn = Conn.put_resp_content_type(conn, "application/json")
    conn = Conn.send_resp(conn, 401, ~s({"error":"invalid_bearer"}))
    Conn.halt(conn)
  end
end
