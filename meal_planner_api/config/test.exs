import Config

config :meal_planner_api, MealPlannerApi.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: System.get_env("MYFOOD_TEST_DATABASE", "meal_planner_api_test"),
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

# RevenueCat access enforcement: no ambient signing secret (each test provides
# its own) and enforcement disabled by default, matching the production rollout.
config :meal_planner_api,
  revenuecat_webhook_signing_secret: nil,
  revenuecat_access_enforcement: false

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Force mock AI client for tests
config :meal_planner_api, :ai_client, MealPlannerApi.AI.MockClient

config :meal_planner_api, MealPlannerApi.Auth.Guardian, secret_key: "test_guardian_secret_key"

# Force mock optimizer client for deterministic planning tests
config :meal_planner_api,
  planning_optimizer_client: MealPlannerApi.Optimization.OptimizerMock,
  start_optimizer_server: false

# Email-code auth — Bamboo LocalAdapter captures deliveries in test
# (`Bamboo.SentEmail.all/0` under LocalAdapter). No outbound SMTP.
config :meal_planner_api, MealPlannerApi.Mailer, adapter: Bamboo.LocalAdapter

# Planning agent: never reach a paid provider or the Python optimizer from
# tests unless a test opts in explicitly.
config :meal_planner_api, :planning_agent,
  model: {MealPlannerApi.PlanningAgent.Model.Scripted, []},
  optimizer: {MealPlannerApi.PlanningAgent.Optimizer.Unavailable, []},
  price_scraper: {MealPlannerApi.PlanningAgent.PriceScraper.Unavailable, []},
  # Generous so tests that start many sessions are not limited; the limit
  # itself is covered by tests that pass `:session_start_limit`.
  session_start_limit: {1_000, 60}
