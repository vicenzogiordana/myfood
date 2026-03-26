import Config

config :meal_planner_api, MealPlannerApi.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "meal_planner_api_test",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :meal_planner_api, MealPlannerApiWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "3JImlj5KrSHLvSOT1KQW8AU+afh44jAAHLIfgHxqNOru3r54ntWTSu0bCKHoDKrK",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Force mock AI client for tests
config :meal_planner_api, :ai_client, MealPlannerApi.AI.MockClient

# Force mock optimizer client for deterministic planning tests
config :meal_planner_api, :planning_optimizer_client, MealPlannerApi.Planning.MockOptimizerClient
