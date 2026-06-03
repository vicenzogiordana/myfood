defmodule MealPlannerApi.Voice.RuleBasedVoiceParserTest do
  use ExUnit.Case, async: true

  alias MealPlannerApi.Voice.RuleBasedVoiceParser

  @items [
    %{id: "i1", name: "verduras", quantity_milli: 200_000},
    %{id: "i2", name: "pollo", quantity_milli: 500_000},
    %{id: "i3", name: "arroz", quantity_milli: 300_000}
  ]

  describe "parse/2" do
    test "handles 'mitad del kilo de verduras' → 500ml" do
      assert {:ok, [%{inventory_item_id: "i1", quantity_milli: 500_000}]} =
               RuleBasedVoiceParser.parse("mitad del kilo de verduras", @items)
    end

    test "handles 'mitad verduras' → half of current quantity" do
      assert {:ok, [%{inventory_item_id: "i1", quantity_milli: 100_000}]} =
               RuleBasedVoiceParser.parse("mitad verduras", @items)
    end

    test "handles 'medio pollo' → half of current quantity" do
      assert {:ok, [%{inventory_item_id: "i2", quantity_milli: 250_000}]} =
               RuleBasedVoiceParser.parse("medio pollo", @items)
    end

    test "handles 'terminé verduras' → 0" do
      assert {:ok, [%{inventory_item_id: "i1", quantity_milli: 0}]} =
               RuleBasedVoiceParser.parse("terminé verduras", @items)
    end

    test "handles 'terminé de usar arroz' → 0" do
      assert {:ok, [%{inventory_item_id: "i3", quantity_milli: 0}]} =
               RuleBasedVoiceParser.parse("terminé de usar arroz", @items)
    end

    test "mentioned item → quarter of current quantity" do
      assert {:ok, [%{inventory_item_id: "i1", quantity_milli: 50_000}]} =
               RuleBasedVoiceParser.parse("usdé verduras", @items)
    end

    test "no mention → empty list" do
      assert {:ok, []} = RuleBasedVoiceParser.parse("no sé qué hice", @items)
    end

    test "multiple items in one text" do
      assert {:ok, ops} = RuleBasedVoiceParser.parse("mitad verduras y usé medio pollo", @items)
      assert length(ops) == 2
      assert Enum.find(ops, &(&1.inventory_item_id == "i1"))
      assert Enum.find(ops, &(&1.inventory_item_id == "i2"))
    end

    test "returns {:ok, []} for empty items list" do
      assert {:ok, []} = RuleBasedVoiceParser.parse("mitad del kilo de algo", [])
    end
  end
end
