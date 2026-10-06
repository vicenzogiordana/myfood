defmodule MealPlannerApiWeb.ShoppingChannel do
  @moduledoc "Account-scoped shopping and inventory lifecycle notifications."
  use MealPlannerApiWeb, :channel
  alias MealPlannerApi.Persistence.Accounts.AccountMembershipQueries
  alias MealPlannerApiWeb.{ChannelCapability, Plugs.LoadCurrentMembershipSocket}

  intercept [
    "cart_reserved",
    "cart_released",
    "cart_expired",
    "cart_renewed",
    "purchase_confirmed",
    "inventory_changed"
  ]

  @impl true
  def join("shopping:" <> account_id, _, socket) do
    membership = LoadCurrentMembershipSocket.membership_from_socket(socket)

    if membership && membership.account_id == account_id && authorized?(membership) do
      {:ok, assign(socket, :current_membership, membership)}
    else
      {:error, %{reason: "forbidden"}}
    end
  end

  @impl true
  def handle_out(event, payload, socket) do
    if authorized?(socket.assigns.current_membership), do: push(socket, event, payload)
    {:noreply, socket}
  end

  @impl true
  def handle_in(_, _, socket), do: {:reply, {:error, %{reason: "unsupported_command"}}, socket}

  defp authorized?(membership) do
    case AccountMembershipQueries.load_active_membership(
           membership.user_id,
           membership.account_id
         ) do
      nil -> false
      current -> ChannelCapability.authorize(current) == :ok
    end
  end
end
