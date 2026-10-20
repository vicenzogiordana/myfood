defmodule MealPlannerApi.PlanningAgent.IngredientMatchTest do
  @moduledoc """
  Similarity matching of Ingredient names against the catalog (issue #160):
  trigram similarity over unaccented, lowercased names finds spelling
  variants, plurals, accents and typos, ranked best first; unrelated names
  stay below the threshold. Only an unambiguous spelling variant resolves on
  its own.
  """

  use ExUnit.Case, async: false

  alias MealPlannerApi.Persistence.Catalog
  alias MealPlannerApi.PlanningAgent.IngredientMatch
  alias MealPlannerApi.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    names =
      ~w(Muzzarella Manzana Lentejas Huevos Arvejas) ++
        ["Harina de trigo", "Limón", "Tomate", "Leche entera", "Pechuga de pollo"]

    ingredients =
      Map.new(names, fn name ->
        {:ok, ingredient} = Catalog.create_ingredient(%{name: name, category: :otros})
        {name, ingredient}
      end)

    %{ingredients: ingredients}
  end

  describe "close_matches/1" do
    test "finds spelling variants ranked by similarity" do
      matches = IngredientMatch.close_matches(["mozzarella", "harina 000", "harina"])

      assert hd(matches["mozzarella"]) == "Muzzarella"
      assert hd(matches["harina 000"]) == "Harina de trigo"
      assert hd(matches["harina"]) == "Harina de trigo"
    end

    test "finds accent, plural and typo variants" do
      matches = IngredientMatch.close_matches(["limon", "huevo", "tomates", "tomatoe", "pollo"])

      assert hd(matches["limon"]) == "Limón"
      assert hd(matches["huevo"]) == "Huevos"
      assert hd(matches["tomates"]) == "Tomate"
      assert hd(matches["tomatoe"]) == "Tomate"
      assert hd(matches["pollo"]) == "Pechuga de pollo"
    end

    test "unrelated names stay below the threshold" do
      matches = IngredientMatch.close_matches(["mozzarella", "Imaginary truffle", "arroz"])

      refute "Manzana" in matches["mozzarella"]
      assert matches["Imaginary truffle"] == []
      refute "Arvejas" in matches["arroz"]
    end
  end

  describe "resolve/1" do
    test "resolves exact names and unambiguous spelling variants", %{ingredients: ingredients} do
      resolved = IngredientMatch.resolve(["MUZZARELLA", "limon", "huevo", "Tomates"])

      assert resolved["MUZZARELLA"].id == ingredients["Muzzarella"].id
      assert resolved["limon"].id == ingredients["Limón"].id
      assert resolved["huevo"].id == ingredients["Huevos"].id
      assert resolved["Tomates"].id == ingredients["Tomate"].id
    end

    test "never resolves a merely similar name" do
      resolved = IngredientMatch.resolve(["mozzarella", "harina", "leche descremada"])

      assert resolved == %{}
    end

    test "never resolves an ambiguous variant" do
      {:ok, _} = Catalog.create_ingredient(%{name: "Tomates", category: :otros})

      refute Map.has_key?(IngredientMatch.resolve(["tomate."]), "tomate.")
    end
  end
end
