defmodule MealPlannerApi.MixProject do
  use Mix.Project

  def project do
    [
      app: :meal_planner_api,
      version: "0.1.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      docs: docs(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  defp docs do
    [
      extras: ["docs/CHANNELS.md"],
      main: "overview",
      api_reference: true,
      source_ref: "main",
      source_url: "https://github.com/your-org/meal_planner_api"
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {MealPlannerApi.Application, []},
      extra_applications: [:logger, :runtime_tools, :inets, :ssl]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.5"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:hackney, "~> 1.18"},
      {:tesla, "~> 1.7"},
      {:jason, "~> 1.2"},
      {:guardian, "~> 2.4"},
      {:bcrypt_elixir, "~> 3.1"},
      {:ecto_sql, "~> 3.12"},
      {:postgrex, ">= 0.0.0"},
      {:cors_plug, "~> 3.0"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},
      {:uuid, "~> 1.1"},
      {:mox, "~> 1.1", only: :test},
      {:ex_doc, "~> 0.36", only: :dev, runtime: false}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get"],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"]
    ]
  end
end
