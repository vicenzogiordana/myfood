defmodule MealPlannerApi.Issue38Database do
  @moduledoc false

  def enabled? do
    config = MealPlannerApi.Repo.config()
    database = config[:database]

    Mix.env() == :test and is_binary(database) and
      Regex.match?(~r/^meal_planner_api_test_issue38_[a-z0-9_]+$/, database) and
      config[:hostname] in ["localhost", "127.0.0.1", "::1"] and
      is_nil(config[:url]) and is_nil(config[:socket_dir]) and
      Application.get_env(:meal_planner_api, :issue38_fresh_database) == database
  end

  def database! do
    unless enabled?(), do: raise("requires a newly created loopback issue38 test database")
    MealPlannerApi.Repo.config()[:database]
  end
end
