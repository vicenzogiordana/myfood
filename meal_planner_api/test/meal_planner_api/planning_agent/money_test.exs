defmodule MealPlannerApi.PlanningAgent.MoneyTest do
  @moduledoc """
  Code-formatted money for the model (issue #160): integer cents become a
  human amount the model quotes as is, next to the cents.
  """

  use ExUnit.Case, async: true

  alias MealPlannerApi.PlanningAgent.Money

  test "formats cents with thousands and decimal separators" do
    assert Money.format(4_995_000) == "ARS 49.950,00"
    assert Money.format(4_500_000, "ARS") == "ARS 45.000,00"
    assert Money.format(0) == "ARS 0,00"
    assert Money.format(5) == "ARS 0,05"
    assert Money.format(123_456_789) == "ARS 1.234.567,89"
    assert Money.format(-30_000) == "ARS -300,00"
    assert Money.format(1_250, "USD") == "USD 12,50"
  end

  test "annotates every integer *_cents field beside it, nested included" do
    content = %{
      "purchase_total_cents" => 4_995_000,
      "currency" => "ARS",
      "budget" => %{"budget_cents" => 4_500_000, "within_budget" => false},
      "prices" => [%{"price_cents" => 1_250, "currency" => "USD"}],
      "none_cents" => nil
    }

    assert Money.annotate(content) == %{
             "purchase_total_cents" => 4_995_000,
             "purchase_total" => "ARS 49.950,00",
             "currency" => "ARS",
             "budget" => %{
               "budget_cents" => 4_500_000,
               "budget" => "ARS 45.000,00",
               "within_budget" => false
             },
             "prices" => [%{"price_cents" => 1_250, "price" => "USD 12,50", "currency" => "USD"}],
             "none_cents" => nil
           }
  end

  test "never overwrites a field already named like the amount" do
    assert Money.annotate(%{"cost_cents" => 100, "cost" => %{"x" => 1}}) == %{
             "cost_cents" => 100,
             "cost" => %{"x" => 1},
             "cost_formatted" => "ARS 1,00"
           }
  end
end
