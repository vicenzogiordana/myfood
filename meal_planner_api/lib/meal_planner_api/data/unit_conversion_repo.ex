defmodule MealPlannerApi.Data.UnitConversionRepo do
  @moduledoc """
  Data access for ingredient_base_units and unit_conversions.

  No business logic — just queries for the price-sync pipeline.
  """

  import Ecto.Query, warn: false

  alias MealPlannerApi.Repo
  alias MealPlannerApi.Persistence.Catalog.{IngredientBaseUnit, UnitConversion}

  # -------------------------------------------------------------------------
  # IngredientBaseUnit
  # -------------------------------------------------------------------------

  @spec get_base_unit(pos_integer()) :: String.t() | nil
  def get_base_unit(ingredient_id) do
    Repo.get_by(IngredientBaseUnit, ingredient_id: ingredient_id)
    |> case do
      nil -> nil
      record -> record.base_unit
    end
  end

  @spec get_base_units([pos_integer()]) :: %{pos_integer() => String.t()}
  def get_base_units(ingredient_ids) when is_list(ingredient_ids) do
    from(bu in IngredientBaseUnit,
      where: bu.ingredient_id in ^ingredient_ids,
      select: {bu.ingredient_id, bu.base_unit}
    )
    |> Repo.all()
    |> Enum.into(%{})
  end

  @spec upsert_base_unit(pos_integer(), String.t()) :: {:ok, IngredientBaseUnit.t()}
  def upsert_base_unit(ingredient_id, base_unit) do
    case Repo.get_by(IngredientBaseUnit, ingredient_id: ingredient_id) do
      nil ->
        %IngredientBaseUnit{ingredient_id: ingredient_id}
        |> IngredientBaseUnit.changeset(%{base_unit: base_unit})
        |> Repo.insert(on_conflict: :replace_all_except_id)

      existing ->
        existing
        |> IngredientBaseUnit.changeset(%{base_unit: base_unit})
        |> Repo.update()
    end
  end

  # -------------------------------------------------------------------------
  # UnitConversion
  # -------------------------------------------------------------------------

  @spec get_conversion_factor(pos_integer(), String.t()) :: float() | nil
  def get_conversion_factor(ingredient_id, from_unit) do
    Repo.get_by(UnitConversion, ingredient_id: ingredient_id, from_unit: from_unit)
    |> case do
      nil -> nil
      record -> record.factor_to_base
    end
  end

  @spec get_conversions_for_ingredient(pos_integer()) :: %{String.t() => float()}
  def get_conversions_for_ingredient(ingredient_id) do
    from(uc in UnitConversion,
      where: uc.ingredient_id == ^ingredient_id,
      select: {uc.from_unit, uc.factor_to_base}
    )
    |> Repo.all()
    |> Enum.into(%{})
  end

  @spec upsert_conversion(pos_integer(), String.t(), float()) :: {:ok, UnitConversion.t()}
  def upsert_conversion(ingredient_id, from_unit, factor_to_base) do
    case Repo.get_by(UnitConversion, ingredient_id: ingredient_id, from_unit: from_unit) do
      nil ->
        %UnitConversion{ingredient_id: ingredient_id}
        |> UnitConversion.changeset(%{from_unit: from_unit, factor_to_base: factor_to_base})
        |> Repo.insert(on_conflict: :replace_all_except_id)

      existing ->
        existing
        |> UnitConversion.changeset(%{from_unit: from_unit, factor_to_base: factor_to_base})
        |> Repo.update()
    end
  end

  @spec list_all_conversions() :: [UnitConversion.t()]
  def list_all_conversions do
    Repo.all(UnitConversion)
  end
end
