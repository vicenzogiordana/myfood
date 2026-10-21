import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/meal_planner_api start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :meal_planner_api, MealPlannerApiWeb.Endpoint, server: true
end

config :meal_planner_api, MealPlannerApiWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() != :test do
  ai_client_module =
    case System.get_env("AI_CLIENT", "gemini") do
      "gemini" ->
        MealPlannerApi.AI.GeminiClient

      "mock" ->
        raise "AI_CLIENT=mock is forbidden outside test environment"

      other ->
        raise "Unsupported AI_CLIENT=#{other}. Supported value: gemini"
    end

  config :meal_planner_api, :ai_client, ai_client_module
end

# Tenancy v2 cutover flag. Off by default; flip MEAL_PLANNER_TENANCY_V2=true as a
# separate post-deploy operation to start minting access_v2 tokens. Tests manage
# :tenancy_v2_only themselves, so the binding is skipped in the test environment.
if config_env() != :test do
  config :meal_planner_api,
         :tenancy_v2_only,
         System.get_env("MEAL_PLANNER_TENANCY_V2", "")
         |> String.trim()
         |> String.downcase()
         |> Kernel.in(["true", "1", "yes", "on"])
end

# RevenueCat access enforcement. The signing secret is the trust anchor for
# webhook ingestion; enforcement of product access stays OFF until the signed
# pipeline is verified in production (see the rollout in design.md). Tests
# manage both keys themselves.
if config_env() != :test do
  config :meal_planner_api,
    revenuecat_webhook_signing_secret: System.get_env("REVENUECAT_WEBHOOK_SIGNING_SECRET"),
    revenuecat_access_enforcement:
      System.get_env("REVENUECAT_ACCESS_ENFORCEMENT", "")
      |> String.trim()
      |> String.downcase()
      |> Kernel.in(["true", "1", "yes", "on"])
end

# Planning agent model adapter and aggregate limits. Every cap, price and
# limit stays nil unless set, and paid execution is refused while any of them
# is missing. The spend cap (micro-USD) and token cap apply per Planning
# Session: the spend cap is the real limit, the token cap only a safety net
# (issue #154); the concurrency caps are global and the start rate limit applies
# per Household (issue #118). A malformed value (not a whole integer) reads
# as unset instead of crashing boot, so the refusal applies.
#
# PLANNING_AGENT_MODEL_PROVIDER selects the adapter (issue #141): `claude`
# for ClaudeMessages, anything else (or unset) for OpenAIResponses. Both
# share the caps; each reads its own key and prices.
if config_env() != :test do
  optional_integer = fn name ->
    with value when is_binary(value) <- System.get_env(name),
         {integer, ""} <- Integer.parse(String.trim(value)) do
      integer
    else
      _ -> nil
    end
  end

  config :meal_planner_api, MealPlannerApi.PlanningAgent.Model.OpenAIResponses,
    api_key: System.get_env("OPENAI_API_KEY"),
    spend_cap_micros: optional_integer.("PLANNING_AGENT_SPEND_CAP_MICROS"),
    token_cap: optional_integer.("PLANNING_AGENT_TOKEN_CAP"),
    input_price_micros_per_mtok: optional_integer.("OPENAI_INPUT_PRICE_MICROS_PER_MTOK"),
    output_price_micros_per_mtok: optional_integer.("OPENAI_OUTPUT_PRICE_MICROS_PER_MTOK"),
    max_concurrent_calls: optional_integer.("PLANNING_AGENT_MAX_CONCURRENT_PROVIDER_CALLS")

  optional_string = fn name ->
    with value when is_binary(value) <- System.get_env(name),
         value when value != "" <- String.trim(value) do
      value
    else
      _ -> nil
    end
  end

  config :meal_planner_api,
         MealPlannerApi.PlanningAgent.Model.ClaudeMessages,
         [
           api_key: System.get_env("ANTHROPIC_API_KEY"),
           spend_cap_micros: optional_integer.("PLANNING_AGENT_SPEND_CAP_MICROS"),
           token_cap: optional_integer.("PLANNING_AGENT_TOKEN_CAP"),
           max_concurrent_calls:
             optional_integer.("PLANNING_AGENT_MAX_CONCURRENT_PROVIDER_CALLS"),
           input_price_micros_per_mtok:
             optional_integer.("ANTHROPIC_INPUT_PRICE_MICROS_PER_MTOK"),
           output_price_micros_per_mtok:
             optional_integer.("ANTHROPIC_OUTPUT_PRICE_MICROS_PER_MTOK"),
           cache_write_price_micros_per_mtok:
             optional_integer.("ANTHROPIC_CACHE_WRITE_PRICE_MICROS_PER_MTOK"),
           cache_read_price_micros_per_mtok:
             optional_integer.("ANTHROPIC_CACHE_READ_PRICE_MICROS_PER_MTOK"),
           fallback_input_price_micros_per_mtok:
             optional_integer.("ANTHROPIC_FALLBACK_INPUT_PRICE_MICROS_PER_MTOK"),
           fallback_output_price_micros_per_mtok:
             optional_integer.("ANTHROPIC_FALLBACK_OUTPUT_PRICE_MICROS_PER_MTOK")
         ] ++
           Enum.reject(
             [
               model: optional_string.("PLANNING_AGENT_CLAUDE_MODEL"),
               effort: optional_string.("PLANNING_AGENT_CLAUDE_EFFORT"),
               # Server-side refusal fallbacks are off by default: the default
               # model, claude-haiku-5-5, rejects the `fallbacks` parameter.
               # PLANNING_AGENT_CLAUDE_FALLBACKS=true turns them on for models
               # that accept it. Anything else reads as unset.
               fallbacks:
                 Map.get(
                   %{"true" => true, "false" => false},
                   optional_string.("PLANNING_AGENT_CLAUDE_FALLBACKS")
                 )
             ],
             &is_nil(elem(&1, 1))
           )

  model_adapter =
    case optional_string.("PLANNING_AGENT_MODEL_PROVIDER") do
      provider when is_binary(provider) ->
        if String.downcase(provider) == "claude",
          do: MealPlannerApi.PlanningAgent.Model.ClaudeMessages,
          else: MealPlannerApi.PlanningAgent.Model.OpenAIResponses

      nil ->
        MealPlannerApi.PlanningAgent.Model.OpenAIResponses
    end

  config :meal_planner_api, MealPlannerApi.PlanningAgent.Optimizer.Port,
    max_concurrent_runs: optional_integer.("PLANNING_AGENT_MAX_CONCURRENT_OPTIMIZER_RUNS")

  session_start_limit =
    case {optional_integer.("PLANNING_AGENT_SESSION_STARTS_PER_WINDOW"),
          optional_integer.("PLANNING_AGENT_SESSION_START_WINDOW_SECONDS")} do
      {max_starts, window_seconds} when is_integer(max_starts) and is_integer(window_seconds) ->
        {max_starts, window_seconds}

      _ ->
        nil
    end

  config :meal_planner_api, :planning_agent,
    session_start_limit: session_start_limit,
    model: {model_adapter, []}
end

# Planning agent live prices. Production reads the price scraper URL from
# GO_SCRAPER_URL; without it no live refresh is attempted (Unavailable) rather
# than calling a localhost default. The URL goes in the adapter options, not
# :go_scraper_url, which GoScraperClient reads at compile time.
if config_env() == :prod do
  price_scraper =
    case String.trim(System.get_env("GO_SCRAPER_URL", "")) do
      "" -> {MealPlannerApi.PlanningAgent.PriceScraper.Unavailable, []}
      url -> {MealPlannerApi.PlanningAgent.PriceScraper.Http, [base_url: url]}
    end

  config :meal_planner_api, :planning_agent, price_scraper: price_scraper
end

config :meal_planner_api,
  gemini_model: System.get_env("GEMINI_MODEL", "gemini-2.5-flash-lite"),
  gemini_base_url: System.get_env("GEMINI_BASE_URL", "https://generativelanguage.googleapis.com"),
  gemini_timeout_ms: String.to_integer(System.get_env("GEMINI_TIMEOUT_MS", "15000"))

google_client_ids =
  System.get_env("GOOGLE_OAUTH_CLIENT_IDS", "")
  |> String.split(",", trim: true)
  |> Enum.map(&String.trim/1)
  |> Enum.reject(&(&1 == ""))

apple_client_ids =
  System.get_env("APPLE_OAUTH_CLIENT_IDS", "")
  |> String.split(",", trim: true)
  |> Enum.map(&String.trim/1)
  |> Enum.reject(&(&1 == ""))

config :meal_planner_api,
  google_oauth_client_ids: google_client_ids,
  apple_oauth_client_ids: apple_client_ids,
  facebook_app_id: System.get_env("FACEBOOK_APP_ID"),
  facebook_app_secret: System.get_env("FACEBOOK_APP_SECRET"),
  google_tokeninfo_url:
    System.get_env("GOOGLE_TOKENINFO_URL", "https://oauth2.googleapis.com/tokeninfo"),
  apple_jwks_url: System.get_env("APPLE_JWKS_URL", "https://appleid.apple.com/auth/keys"),
  facebook_graph_url: System.get_env("FACEBOOK_GRAPH_URL", "https://graph.facebook.com")

if config_env() == :prod do
  guardian_secret_key =
    System.get_env("GUARDIAN_SECRET_KEY") ||
      raise """
      environment variable GUARDIAN_SECRET_KEY is missing.
      Set it to a securely generated secret before starting the application.
      """

  config :meal_planner_api, MealPlannerApi.Auth.Guardian, secret_key: guardian_secret_key

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :meal_planner_api, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :meal_planner_api, MealPlannerApiWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :meal_planner_api, MealPlannerApiWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :meal_planner_api, MealPlannerApiWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
