defmodule MealPlannerApiWeb.UserSocket do
  @moduledoc """
  Phoenix Socket handler for real-time WebSocket connections.

  ## Authentication

  Clients authenticate by passing a JWT token in the connection params:

  ```javascript
  // JavaScript client example using Phoenix Socket
  import { Socket } from "phoenix";

  const socket = new Socket("/socket", {
    params: { token: "<your-jwt-token>" }
  });

  socket.connect();

  // Join a specific channel
  const channel = socket.channel("ai_chat:session_123", {});
  channel.join()
    .receive("ok", resp => console.log("Joined!", resp))
    .receive("error", resp => console.log("Unable to join", resp));
  ```

  The token is validated using `Guardian.resource_from_token/1`. If the token
  is invalid or missing, the connection is rejected with `:error`.

  ## Channels

  This socket multiplexes four main topic namespaces:

  | Channel Pattern | Module | Purpose | Key Events |
  |-----------------|--------|---------|------------|
  | `ai_chat:*` | `AIChannel` | AI meal planning assistant | `new_message`, `regenerate` |
  | `calendar:*` | `CalendarChannel` | Calendar operations | `slot_updated`, `meal_assigned` |
  | `planning:*` | `PlanningChannel` | Weekly planning | `plan_generated`, `slot_chosen` |
  | `cooking:*` | `CookingChannel` | Cooking mode | `step_complete`, `timer_start` |

  ## Token Refresh

  When a user's JWT token expires, the socket will disconnect automatically.
  Clients should implement reconnection logic:

  ```javascript
  socket.onError(() => {
    if (socket.connectionState() === "error") {
      // Token may have expired — refresh and reconnect
      return refreshToken().then(token => {
        socket.params = { token };
        socket.connect();
      });
    }
  });
  ```

  The socket ID format is `user_socket:<user_id>`, which allows the
  application to push messages to specific users.

  ## Disconnection

  On disconnection, Phoenix Channels handles presence cleanup automatically.
  Presence tracking (if used) will remove the user's presence from all joined
  channels. No manual cleanup is required in most cases.

  See `Phoenix.Channel` for channel implementation details.
  """
  use Phoenix.Socket

  channel("ai_chat:*", MealPlannerApiWeb.AIChannel)
  channel("calendar:*", MealPlannerApiWeb.CalendarChannel)
  channel("planning:*", MealPlannerApiWeb.PlanningChannel)
  channel("cooking:*", MealPlannerApiWeb.CookingChannel)

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) do
    with {:ok, user, claims} <- MealPlannerApi.Auth.Guardian.resource_from_token(token),
         {:ok, membership} <- load_membership_for_socket(socket, user, claims) do
      socket =
        socket
        |> assign(:current_user, user)
        |> assign(:claims, claims)
        |> assign(:current_membership, membership)

      {:ok, socket}
    else
      _ -> :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  # Loads the membership for a freshly-connected socket. Populates both
  # the legacy `claims` assign (for any caller that reads it directly)
  # and the canonical `current_membership` assign that channels consume.
  #
  # Post-PR-3b review — BLOCKER fix (legacy membership synthesis) +
  # duplication cleanup: this used to have its OWN private
  # `synthesize_legacy_membership/2`, a 4th independent copy of the
  # "fabricate an :active membership from user.account_id, no DB lookup"
  # bug pattern (in addition to the 3 named in the review) — a removed
  # member's stale legacy token could open a live socket connection for
  # up to Guardian's 4-week token TTL. Both the `access_v2` AND `access`
  # branches now delegate to `LoadCurrentMembershipSocket.
  # membership_from_socket/1`, which requires a real, `:active`
  # `AccountMembership` row for legacy tokens too — one implementation,
  # one fix, no more duplicate.
  defp load_membership_for_socket(socket, user, claims) do
    socket_with_context =
      socket
      |> assign(:current_user, user)
      |> assign(:claims, claims)

    case MealPlannerApiWeb.Plugs.LoadCurrentMembershipSocket.membership_from_socket(
           socket_with_context
         ) do
      %MealPlannerApi.Persistence.Accounts.AccountMembership{} = m -> {:ok, m}
      _ -> {:error, :membership_id_required}
    end
  end

  @impl true
  def id(socket) do
    "user_socket:" <> socket.assigns.current_user.id
  end
end
