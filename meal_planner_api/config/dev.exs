import Config

config :meal_planner_api, MealPlannerApi.Repo,
  username: System.get_env("DB_USER", "postgres"),
  password: System.get_env("DB_PASSWORD", "postgres"),
  hostname: System.get_env("DB_HOST", "localhost"),
  database: System.get_env("DB_NAME", "meal_planner_api_dev"),
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

# For development, we disable any cache and enable
# debugging and code reloading.
#
# The watchers configuration can be used to run external
# watchers to your application. For example, we can use it
# to bundle .js and .css sources.
config :meal_planner_api, MealPlannerApiWeb.Endpoint,
  # Binding to loopback ipv4 address prevents access from other machines.
  # Change to `ip: {0, 0, 0, 0}` to allow access from other machines.
  http: [ip: {127, 0, 0, 1}],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base:
    System.get_env("SECRET_KEY_BASE") ||
      "dn65eHJgfhuUbcC/fmebcPK2uTb1QYEaDBc8rC9uhD6BZe7OMCGfy2BX4fnboii1",
  watchers: [],
  optimizer_python: System.get_env("OPTIMIZER_PYTHON", "python3"),
  optimizer_script_path:
    System.get_env(
      "OPTIMIZER_SCRIPT_PATH",
      "/Users/vicenzogiordana/Desktop/Progra/myfood/optimizador.py"
    ),
  # v2 Planning: external service URLs
  python_optimizer_url: System.get_env("PYTHON_OPTIMIZER_URL", "http://localhost:8000"),
  go_scraper_url: System.get_env("GO_SCRAPER_URL", "http://localhost:4001"),
  optimize_timeout_ms: 60_000,
  # v2 Planning: external service URLs
  python_optimizer_url: System.get_env("PYTHON_OPTIMIZER_URL", "http://localhost:8000"),
  go_scraper_url: System.get_env("GO_SCRAPER_URL", "http://localhost:4001"),
  optimize_timeout_ms: 60_000

# For development, we disable any cache and enable
# debugging and code reloading.
#
#     https: [
#       port: 4001,
#       cipher_suite: :strong,
#       keyfile: "priv/cert/selfsigned_key.pem",
#       certfile: "priv/cert/selfsigned.pem"
#     ],
#
# If desired, both `http:` and `https:` keys can be
# configured to run both http and https servers on
# different ports.

# Enable dev routes for dashboard and mailbox
config :meal_planner_api, dev_routes: true

# Do not include metadata nor timestamps in development logs
config :logger, :default_formatter, format: "[$level] $message\n"

# Set a higher stacktrace during development. Avoid configuring such
# in production as building large stacktraces may be expensive.
config :phoenix, :stacktrace_depth, 20

# Initialize plugs at runtime for faster development compilation
config :phoenix, :plug_init_mode, :runtime
