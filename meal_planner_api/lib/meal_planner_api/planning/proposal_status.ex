defmodule MealPlannerApi.Planning.ProposalStatus do
  @moduledoc """
  Code-owned status of a Proposal (spec #93, user stories 62–64).

    * `:invalid` — the validator found violations; the Proposal is never
      shown and the violations go back to the agent
    * `:requires_approval` — valid, but it has Deviations (budget, a day's
      calories or a day's macros); it is shown with its exact Deviations and
      needs a Deviation Approval before it can be confirmed
    * `:valid` — valid and meeting every goal

  Deviations come from `MealPlannerApi.Optimization.Contract.interpret/1`.
  """

  @type t :: :valid | :requires_approval | :invalid

  @doc "Classifies a Proposal from its validator violations and its Deviations."
  @spec classify([term()], [term()]) :: t()
  def classify([_ | _] = _violations, _deviations), do: :invalid
  def classify([], [_ | _] = _deviations), do: :requires_approval
  def classify([], []), do: :valid
end
