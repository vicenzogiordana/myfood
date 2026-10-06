defmodule MealPlannerApi.CookingBarrierClient do
  @moduledoc false
  def generate_text(prompt, opts) do
    send(
      Application.fetch_env!(:meal_planner_api, :cooking_test_owner),
      {:cooking_ai, self(), prompt, opts}
    )

    receive do
      :answer -> {:ok, "Use the frozen instructions."}
    after
      5_000 -> {:error, :test_timeout}
    end
  end
end
