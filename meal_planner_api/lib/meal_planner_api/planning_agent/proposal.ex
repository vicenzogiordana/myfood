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
  alias MealPlannerApi.PlanningAgent.{Diners, Purchase, RecipeDraft, Workspace}

  @type t :: map()

  # Fields that make up what the Member saw; the identity is not one of them.
  @content_fields ~w(status meals skipped purchase consumed_cost budget deviations)

  @doc """
  Builds a Proposal for `meals` (validated, each with `:date`, `:slot`,
  `:recipe_id`, `:name`, `:origin`, `:draft` and `:servings`) in the
  session context `ctx`. Every meal is scaled to its diners
  (`MealPlannerApi.PlanningAgent.Diners`) and shows them with its guests and
  the batches of its recipe they need. Every meal shows its Recipe Origin, and a Recipe Draft is marked as
  one so the Member sees it is AI-created and not yet saved. The meals the
  Household does not eat at home are listed under `skipped` (issue #160):
  they have no meal, so the Purchase and the consumed cost leave them out. Prices are
  aged at the context's `:clock` (default: the current time), and the
  Purchase follows the context's chosen brands (`brand_choices/1`). Returns
  the Proposal event and the Purchase it carries.
  """
  @spec build([map()], map()) :: {t(), Purchase.t()}
  def build(meals, ctx) do
    meals = Diners.annotate(meals, ctx)

    purchase =
      Purchase.for_meals(meals, ctx.account_id, RecipeDraft.in_context(ctx),
        now: now(ctx),
        brands: brand_choices(ctx)
      )

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
            "draft" => meal.draft,
            "diners" => meal.diners,
            "guests" => meal.guests,
            "batches" => meal.batches
          }
        end),
      "skipped" => ctx |> Workspace.skipped() |> Workspace.skipped_data(ctx.slots),
      "purchase" => Purchase.to_data(purchase),
      "consumed_cost" => Purchase.consumed_data(purchase),
      "budget" => budget_data(purchase, ctx.household.budget_cents),
      "deviations" => deviations
    }

    {proposal, purchase}
  end

  @doc """
  The chosen brand per ingredient id in the session context `ctx`: a Session
  Brand (`:session_brands`, else the Workspace's) beats the Household's Brand
  Preference.
  """
  @spec brand_choices(map()) :: %{Ecto.UUID.t() => Purchase.brand_choice()}
  def brand_choices(ctx) do
    household =
      ctx.household
      |> Map.get(:brand_preferences, [])
      |> Map.new(&{&1.ingredient_id, %{brand: &1.brand, source: :household}})

    session =
      ctx
      |> session_brands()
      |> Map.new(fn {id, %{brand: brand}} -> {id, %{brand: brand, source: :session}} end)

    Map.merge(household, session)
  end

  defp session_brands(%{session_brands: brands}) when is_map(brands), do: brands
  defp session_brands(%{workspace: workspace}), do: Map.get(workspace, :session_brands, %{})
  defp session_brands(_ctx), do: %{}

  @doc """
  The meals of a Proposal, as validator input, with the diners, guests and
  batches it showed (when it shows them).
  """
  @spec meals(t()) :: [%{date: Date.t(), slot: String.t(), recipe_id: String.t()}]
  def meals(%{"meals" => meals}) do
    Enum.map(meals, fn meal ->
      %{date: Date.from_iso8601!(meal["date"]), slot: meal["slot"], recipe_id: meal["recipe_id"]}
      |> Map.merge(scale(meal))
    end)
  end

  defp scale(%{"diners" => diners, "guests" => guests, "batches" => batches}),
    do: %{diners: diners, guests: guests, batches: batches}

  defp scale(_meal), do: %{}

  @doc """
  Whether two Proposals show the Member the same content, whatever their
  identity. The age of a price ticks with the clock and is not content; a
  price turning stale is, through its freshness and the budget certainty.
  """
  @spec same_content?(t(), t()) :: boolean()
  def same_content?(a, b), do: content(a) == content(b)

  # A Proposal shown before #160 has no `skipped`: nothing was skipped.
  defp content(proposal),
    do: proposal |> Map.put_new("skipped", []) |> Map.take(@content_fields) |> without_ages()

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
