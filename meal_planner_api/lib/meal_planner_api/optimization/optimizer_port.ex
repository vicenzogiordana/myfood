defmodule MealPlannerApi.Optimization.OptimizerPort do
  @moduledoc """
  Behaviour for the meal optimization integration.

  Implementors must provide a way to select a weekly menu given candidate
  recipes, nutritional constraints, and budget limits.

  Payloads and successful results use JSON-decoded string keys. Payloads carry
  `"days"`, `"slots"`, `"constraints"`, and `"candidates_by_slot"`; results
  carry `"meals"`, whose entries include `"day"`, `"slot"`, and `"recipe_id"`.
  Candidate maps preserve all input fields (e.g. `"estimated_cost_cents"`,
  `"label"`, `"price_per_serving_cents"`) so downstream code can rely on the
  full candidate shape, not a trimmed subset.

  The port may raise an error for:
  - `:optimizer_timeout` — solver did not respond in time
  - `:optimizer_unavailable` — process is down or circuit is open
  - `:optimizer_error` — solver returned an error (e.g. malformed input)
  """

  @type optimizer_payload :: %{required(String.t()) => term()}

  @type optimizer_constraints :: %{required(String.t()) => term()}

  @type optimizer_result :: {:ok, %{required(String.t()) => [selected_meal()]}} | {:error, term()}

  @type macro_bounds :: %{required(String.t()) => %{required(String.t()) => float()}}

  @type candidate_recipe :: %{required(String.t()) => term()}

  @type selected_meal :: %{required(String.t()) => term()}

  @doc """
  Given a payload describing the planning request, returns a weekly plan.

  The result `meals` list must contain one entry per day × slot combination.
  """
  defmacro __using__(_opts) do
    quote do
      @behaviour unquote(__MODULE__)

      @impl true
      def health_check, do: :ok

      defmacro __before_compile__(env), do: :ok
    end
  end

  @callback select_weekly_menu(optimizer_payload()) :: optimizer_result()

  @doc """
  Returns `:ok` if the optimizer is running and ready to accept requests.
  """
  @callback health_check() :: :ok | {:error, :optimizer_unavailable}
end
