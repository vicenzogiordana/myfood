defmodule MealPlannerApi.Persistence.Shopping do
  @moduledoc "Persistence helpers for supermarkets, shopping items and checkout sessions."

  import Ecto.Query, warn: false

  alias MealPlannerApi.Repo

  alias MealPlannerApi.Persistence.Shopping.{
    CheckoutSession,
    ShoppingItem,
    Supermarket,
    SupermarketCatalog
  }

  def create_supermarket(attrs),
    do: %Supermarket{} |> Supermarket.changeset(attrs) |> Repo.insert()

  def upsert_supermarket_by_name(attrs) do
    %Supermarket{}
    |> Supermarket.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace_all_except, [:id, :inserted_at]},
      conflict_target: [:name]
    )
  end

  def upsert_supermarket_catalog(attrs) do
    %SupermarketCatalog{}
    |> SupermarketCatalog.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:price_cents_ars, :unit, :last_scraped_at, :updated_at]},
      conflict_target: [:supermarket_id, :ingredient_id, :price_date]
    )
  end

  def create_checkout_session(attrs),
    do: %CheckoutSession{} |> CheckoutSession.changeset(attrs) |> Repo.insert()

  def update_checkout_session(session, attrs),
    do: session |> CheckoutSession.changeset(attrs) |> Repo.update()

  def get_checkout_session_for_account(account_id, checkout_session_id) do
    from(s in CheckoutSession,
      where: s.account_id == ^account_id and s.id == ^checkout_session_id,
      limit: 1
    )
    |> Repo.one()
  end

  def list_pending_delivery_sessions(account_id) do
    from(s in CheckoutSession,
      where: s.account_id == ^account_id and s.status == :pending_delivery,
      order_by: [desc: s.inserted_at]
    )
    |> Repo.all()
  end

  def create_shopping_item(attrs),
    do: %ShoppingItem{} |> ShoppingItem.changeset(attrs) |> Repo.insert()

  def update_shopping_item(item, attrs),
    do: item |> ShoppingItem.changeset(attrs) |> Repo.update()

  def list_pending_items(account_id, from_date, to_date) do
    from(i in ShoppingItem,
      where:
        i.account_id == ^account_id and i.status in [:pending, :in_cart] and
          i.planned_date >= ^from_date and i.planned_date <= ^to_date,
      order_by: [asc: i.planned_date]
    )
    |> Repo.all()
  end

  def list_pending_items_with_context(account_id, from_date, to_date) do
    from(i in ShoppingItem,
      where:
        i.account_id == ^account_id and i.status == :pending and
          i.planned_date >= ^from_date and i.planned_date <= ^to_date,
      order_by: [asc: i.planned_date],
      preload: [:assigned_supermarket, :ingredient]
    )
    |> Repo.all()
  end

  def list_in_cart_items_with_context(account_id, from_date, to_date) do
    from(i in ShoppingItem,
      where:
        i.account_id == ^account_id and i.status == :in_cart and i.planned_date >= ^from_date and
          i.planned_date <= ^to_date,
      order_by: [asc: i.planned_date],
      preload: [:assigned_supermarket, :ingredient]
    )
    |> Repo.all()
  end

  def list_items_for_account(account_id) do
    from(i in ShoppingItem,
      where: i.account_id == ^account_id,
      order_by: [asc: i.planned_date]
    )
    |> Repo.all()
  end

  def list_items_by_ids(account_id, ids) when is_list(ids) do
    from(i in ShoppingItem,
      where: i.account_id == ^account_id and i.id in ^ids,
      preload: [:ingredient]
    )
    |> Repo.all()
  end

  def find_item_by_account_meal_ingredient(account_id, scheduled_meal_id, ingredient_id, unit) do
    from(i in ShoppingItem,
      where:
        i.account_id == ^account_id and i.scheduled_meal_id == ^scheduled_meal_id and
          i.ingredient_id == ^ingredient_id and i.unit == ^unit,
      limit: 1
    )
    |> Repo.one()
  end

  def archive_outdated_unpurchased(account_id, date) do
    from(i in ShoppingItem,
      where:
        i.account_id == ^account_id and i.status in [:pending, :in_cart] and
          i.planned_date < ^date
    )
    |> Repo.update_all(set: [status: :archived, updated_at: DateTime.utc_now()])
  end

  def update_open_items_for_ingredient(account_id, ingredient_id, attrs, from_date, to_date) do
    from(i in ShoppingItem,
      where:
        i.account_id == ^account_id and i.ingredient_id == ^ingredient_id and
          i.status in [:pending, :in_cart] and i.planned_date >= ^from_date and
          i.planned_date <= ^to_date
    )
    |> Repo.update_all(set: Keyword.merge(Enum.into(attrs, []), updated_at: DateTime.utc_now()))
  end

  def get_supermarket(supermarket_id), do: Repo.get(Supermarket, supermarket_id)

  def latest_catalog_for_ingredients(ingredient_ids) when is_list(ingredient_ids) do
    from(c in SupermarketCatalog,
      where: c.ingredient_id in ^ingredient_ids,
      join: s in assoc(c, :supermarket),
      order_by: [asc: c.ingredient_id, asc: c.supermarket_id, desc: c.price_date],
      distinct: [c.ingredient_id, c.supermarket_id],
      select: %{
        ingredient_id: c.ingredient_id,
        supermarket_id: c.supermarket_id,
        supermarket_name: s.name,
        price_cents_ars: c.price_cents_ars,
        unit: c.unit,
        price_date: c.price_date
      }
    )
    |> Repo.all()
  end

  def list_items_grouped_by_supermarket(account_id, from_date, to_date) do
    from(i in ShoppingItem,
      where:
        i.account_id == ^account_id and i.status in [:pending, :in_cart] and
          i.planned_date >= ^from_date and i.planned_date <= ^to_date,
      group_by: i.assigned_supermarket_id,
      select: %{assigned_supermarket_id: i.assigned_supermarket_id, count: count(i.id)}
    )
    |> Repo.all()
  end
end
