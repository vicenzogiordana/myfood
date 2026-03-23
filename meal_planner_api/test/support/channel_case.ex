defmodule MealPlannerApiWeb.ChannelCase do
  @moduledoc """
  Test case for channel tests that require pubsub and DB sandbox.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Phoenix.ChannelTest
      @endpoint MealPlannerApiWeb.Endpoint
    end
  end

  setup tags do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(MealPlannerApi.Repo)

    unless tags[:async] do
      Ecto.Adapters.SQL.Sandbox.mode(MealPlannerApi.Repo, {:shared, self()})
    end

    :ok
  end
end
