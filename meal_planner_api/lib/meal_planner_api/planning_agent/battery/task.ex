defmodule MealPlannerApi.PlanningAgent.Battery.Task do
  @moduledoc """
  One task of the quality battery (issue #109, task set agreed in #87).

  A task is declarative data, so every run of it starts from identical
  fictitious fixtures and prepared responses:

    * `:id`, `:title` — stable identity and a short description
    * `:kind` — `:routine` or `:adversarial`
    * `:solvable` — fixed in advance (#87): on a solvable task only a valid
      Proposal is correct; on an unsolvable one only an abstention naming
      the real cause is, and a Proposal presented as valid is a hard-rule
      violation
    * `:kitchen` — the fixtures, built by `MealPlannerApi.PlanningAgent.Battery.Kitchen`
    * `:steps` — what the fictitious Member does, in order:
      `{:message, text}`, `{:confirm, :current}`, `{:confirm_twice, :current}`
      or `{:confirm, :first}` (the first Proposal shown, once a later one
      replaced it)
    * `:cause` — for an unsolvable task, how its real cause shows:
      `:deviations` (code-owned Deviation types of a `requires_approval`
      Proposal), `:limits` (limits the session reached) and `:markers`
      (words the agent's explanation must contain, checked when the
      abstention cause is judged deterministically)
    * `:checks` — the task's relevance checks on its final Proposal:
      `{:uses_ingredient, ingredient}` (a planned recipe uses it),
      `{:purchases_when_planned, ingredient}` (a planned recipe using the
      ingredient must buy it) and `{:changed_meal, date, slot}` (the final
      Proposal changed that meal from the first one and kept every other
      meal)
    * `:tools` — prepared tool responses: `:scraper` (query to answer, see
      `MealPlannerApi.PlanningAgent.Battery.PreparedScraper`),
      `:recipe_search` (`:failing`) and `:optimizer` (`:unavailable`)
  """

  @enforce_keys [:id, :title, :kind, :solvable, :kitchen, :steps]
  defstruct id: nil,
            title: nil,
            kind: nil,
            solvable: nil,
            kitchen: nil,
            steps: [],
            cause: %{deviations: [], limits: [], markers: []},
            checks: [],
            tools: %{}

  @type step ::
          {:message, String.t()}
          | {:confirm, :current | :first}
          | {:confirm_twice, :current}

  @type t :: %__MODULE__{
          id: String.t(),
          title: String.t(),
          kind: :routine | :adversarial,
          solvable: boolean(),
          kitchen: map(),
          steps: [step()],
          cause: %{deviations: [String.t()], limits: [String.t()], markers: [String.t()]},
          checks: [tuple()],
          tools: map()
        }
end
