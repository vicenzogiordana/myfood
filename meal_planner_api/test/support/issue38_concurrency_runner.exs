# Run with MIX_ENV=test mix run --no-start test/support/issue38_concurrency_runner.exs.
# Never reuse or drop a database. The receipt is set only after successful creation.
unless Mix.env() == :test, do: raise("issue38 verification requires MIX_ENV=test")

config = Application.fetch_env!(:meal_planner_api, MealPlannerApi.Repo)

unless config[:hostname] in ["localhost", "127.0.0.1", "::1"] and
         is_nil(config[:url]) and is_nil(config[:socket_dir]) do
  raise "issue38 verification requires a direct loopback database connection"
end

database =
  "meal_planner_api_test_issue38_" <>
    (DateTime.utc_now() |> Calendar.strftime("%Y%m%d%H%M%S")) <>
    "_" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

config =
  config |> Keyword.put(:database, database) |> Keyword.put(:maintenance_database, "postgres")

# Storage creation uses PostgreSQL's maintenance database, never the configured old target.
# Suppress connection diagnostics here: they can contain credentials on failure.
Logger.configure(level: :none)

created? =
  try do
    Ecto.Adapters.Postgres.storage_up(config) == :ok
  rescue
    _ -> false
  catch
    _, _ -> false
  end

unless created?, do: raise("fresh issue38 database creation failed; no tests were started")

Logger.configure(level: :warning)
Application.put_env(:meal_planner_api, MealPlannerApi.Repo, config)
Application.put_env(:meal_planner_api, :issue38_fresh_database, database)
System.put_env("MYFOOD_TEST_DATABASE", database)
IO.puts("Created and retaining fresh test database: #{database}")
Mix.Task.run("ecto.migrate", ["--quiet"])

Mix.Task.run("test", [
  "test/meal_planner_api/services/cooking_atomicity_test.exs",
  "test/meal_planner_api/cart_concurrency_test.exs"
])
