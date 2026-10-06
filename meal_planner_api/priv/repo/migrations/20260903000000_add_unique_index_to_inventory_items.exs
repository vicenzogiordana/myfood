defmodule MealPlannerApi.Repo.Migrations.AddPositiveStockLotLookupIndex do
  use Ecto.Migration

  @index_name :inventory_items_positive_stock_lot_lookup_index

  def up do
    create(
      index(
        :inventory_items,
        [:account_id, :ingredient_id, :unit, :source_kind, :expired_at],
        name: @index_name,
        where: "quantity_milli > 0"
      )
    )
  end

  def down do
    drop(index(:inventory_items, [], name: @index_name))
  end
end
