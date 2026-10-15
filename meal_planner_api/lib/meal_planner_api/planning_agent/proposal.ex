defmodule MealPlannerApi.PlanningAgent.Proposal do
  @moduledoc """
  Builds the Proposal shown to the Member from validated meals (spec #93,
  user stories 55–66): its meals, Purchase, consumed-ingredient cost, budget
  comparison, Deviations and code-owned status. `present_proposal` builds it
  before showing a plan and confirmation rebuilds it from current data to
  revalidate the exact Proposal the Member saw.

  Every Proposal has its own identity (`proposal_id`); a recalculated
  Proposal is a new one and needs its own confirmation.
  """

  alias MealPlannerApi.Planning.ProposalStatus
  alias MealPlannerApi.PlanningAgent.{Purchase, RecipeDraft}

  @type t :: map()

  # Fields that make up what the Member saw; the identity is not one of them.
  @content_fields ~w(status meals purchase consumed_cost budget deviations)

  @doc """
  Builds a Proposal for `meals` (validated, each with `:date`, `:slot`,
  `:recipe_id`, `:name`, `:origin` and `:draft`) in the session context
  `ctx`. Every meal shows its Recipe Origin, and a Recipe Draft is marked as
  one so the Member sees it is AI-created and not yet saved. Prices are
  aged at the context's `:clock` (default: the current time). Returns the
  Proposal event and the Purchase it carries.
  """
  @spec build([map()], map()) :: {t(), Purchase.t()}
  def build(meals, ctx) do
    purchase =
      Purchase.for_meals(meals, ctx.account_id, RecipeDraft.in_context(ctx), now: now(ctx))

    deviations = budget_deviations(purchase, ctx.household.budget_cents)

    proposal = %{
      "type" => "proposal",
      "proposal_id" => Ecto.UUID.generate(),
      "status" => ProposalStatus.classify([], deviations) |> Atom.to_string(),
      "meals" =>
        Enum.map(meals, fn meal ->
          %{
            "date" => Date.to_iso8601(meal.date),
            "slot" => meal.slot,
            "recipe_id" => meal.recipe_id,
            "name" => meal.name,
            "origin" => meal.origin,
            "draft" => meal.draft
          }
        end),
      "purchase" => Purchase.to_data(purchase),
      "consumed_cost" => Purchase.consumed_data(purchase),
      "budget" => budget_data(purchase, ctx.household.budget_cents),
      "deviations" => deviations
    }

    {proposal, purchase}
  end

  @doc "The meals of a Proposal, as validator input."
  @spec meals(t()) :: [%{date: Date.t(), slot: String.t(), recipe_id: String.t()}]
  def meals(%{"meals" => meals}) do
    Enum.map(meals, fn meal ->
      %{date: Date.from_iso8601!(meal["date"]), slot: meal["slot"], recipe_id: meal["recipe_id"]}
    end)
  end

  @doc """
  Whether two Proposals show the Member the same content, whatever their
  identity. The age of a price ticks with the clock and is not content; a
  price turning stale is, through its freshness and the budget certainty.
  """
  @spec same_content?(t(), t()) :: boolean()
  def same_content?(a, b), do: content(a) == content(b)

  defp content(proposal), do: proposal |> Map.take(@content_fields) |> without_ages()

  defp without_ages(map) when is_map(map) and not is_struct(map),
    do: map |> Map.delete("age_hours") |> Map.new(fn {k, v} -> {k, without_ages(v)} end)

  defp without_ages(list) when is_list(list), do: Enum.map(list, &without_ages/1)
  defp without_ages(value), do: value

  defp now(ctx) do
    case Map.get(ctx, :clock) do
      clock when is_function(clock, 0) -> clock.()
      _ -> DateTime.utc_now()
    end
  end

  # The budget is compared against the Purchase total. A budget of zero means
  # the Household has not set one. With missing prices the total is a lower
  # bound: overspend is still certain, but fitting the budget is unknown.
  defp budget_deviations(purchase, budget_cents)
       when is_integer(budget_cents) and budget_cents > 0 and
              purchase.total_cents > budget_cents do
    [
      %{
        "type" => "budget",
        "budget_cents" => budget_cents,
        "total_cents" => purchase.total_cents,
        "difference_cents" => purchase.total_cents - budget_cents
      }
    ]
  end

  defp budget_deviations(_purchase, _budget_cents), do: []

  defp budget_data(purchase, budget_cents) when is_integer(budget_cents) and budget_cents > 0 do
    within =
      cond do
        purchase.total_cents > budget_cents -> false
        purchase.complete? -> true
        true -> nil
      end

    %{
      "budget_cents" => budget_cents,
      "purchase_total_cents" => purchase.total_cents,
      "within_budget" => within,
      "uncertain" => uncertain?(purchase)
    }
  end

  defp budget_data(purchase, _budget_cents) do
    %{
      "budget_cents" => nil,
      "purchase_total_cents" => purchase.total_cents,
      "within_budget" => nil,
      "uncertain" => uncertain?(purchase)
    }
  end

  # Missing and stale prices both make the Purchase total uncertain.
  defp uncertain?(purchase), do: not purchase.complete? or Purchase.stale?(purchase)
end
