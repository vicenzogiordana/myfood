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
    case MealPlannerApi.Auth.Guardian.resource_from_token(token) do
      {:ok, user, _claims} ->
        {:ok, assign(socket, :current_user, user)}

      {:error, _reason} ->
        :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(socket) do
    "user_socket:" <> socket.assigns.current_user.id
  end
end
