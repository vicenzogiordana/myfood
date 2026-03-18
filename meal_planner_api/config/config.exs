# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :meal_planner_api,
  generators: [timestamp_type: :utc_datetime]

config :meal_planner_api, MealPlannerApi.Auth.Guardian,
  issuer: "meal_planner_api",
  secret_key: "change_this_for_prod_only_guardian_secret"

config :meal_planner_api,
  ai_client: MealPlannerApi.AI.MockClient

# Configure the endpoint
config :meal_planner_api, MealPlannerApiWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: MealPlannerApiWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: MealPlannerApi.PubSub,
  live_view: [signing_salt: "xAXCFxOO"]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
