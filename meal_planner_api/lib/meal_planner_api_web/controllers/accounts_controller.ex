defmodule MealPlannerApiWeb.AccountsController do
  use MealPlannerApiWeb, :controller

  alias MealPlannerApi.Services.AccountService

  def me(conn, _params) do
    user = Guardian.Plug.current_resource(conn)

    case AccountService.me(%{
           account_id: user.account_id,
           user_id: user.id
         }) do
      {:ok, account_data} ->
        # Return full response matching test expectations: {user, account, claims}
        json(conn, %{
          user: %{
            id: user.id,
            email: user.email,
            name: user.name,
            subscription_tier: to_string(user.subscription_tier || :free)
          },
          account: account_data,
          claims: %{
            sub: user.id,
            account_id: user.account_id,
            subscription_tier: to_string(user.subscription_tier || :free)
          }
        })

      {:error, reason} ->
        render_error(conn, reason)
    end
  end

  def context(conn, _params) do
    user = Guardian.Plug.current_resource(conn)

    case AccountService.context(%{
           account_id: user.account_id,
           user_id: user.id
         }) do
      {:ok, data} ->
        json(conn, %{
          user: %{
            id: user.id,
            email: user.email,
            name: user.name,
            subscription_tier: to_string(user.subscription_tier || :free)
          },
          account: data.account,
          subscription: data.subscription,
          active_users: data.active_users
        })

      {:error, reason} ->
        render_error(conn, reason)
    end
  end

  defp render_error(conn, reason) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: Atom.to_string(reason)})
  end
end
