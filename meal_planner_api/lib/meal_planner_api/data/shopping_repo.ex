defmodule MealPlannerApi.Data.ShoppingRepo do
  @moduledoc """
  Pure data access for supermarkets, shopping items, and checkout sessions.

  No business logic. No orchestration. Just queries and persistence.
  """

  import Ecto.Query, warn: false
  alias MealPlannerApi.Repo

  alias MealPlannerApi.Persistence.Shopping.{
    CheckoutSession,
    ShoppingItem,
    Supermarket,
    SupermarketCatalog
  }

  # -------------------------------------------------------------------------
  # Supermarkets
  # -------------------------------------------------------------------------

  @spec create_supermarket(map()) :: {:ok, Supermarket.t()} | {:error, Ecto.Changeset.t()}
  def create_supermarket(attrs),
    do: %Supermarket{} |> Supermarket.changeset(attrs) |> Repo.insert()

  @spec upsert_supermarket(map()) :: {:ok, Supermarket.t()} | {:error, Ecto.Changeset.t()}
  def upsert_supermarket(attrs) do
    %Supermarket{}
    |> Supermarket.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace_all_except, [:id, :inserted_at]},
      conflict_target: [:name]
    )
  end

  @spec list_supermarkets() :: [Supermarket.t()]
  def list_supermarkets, do: Repo.all(Supermarket)

  @spec get_supermarket!(pos_integer()) :: Supermarket.t()
  def get_supermarket!(id), do: Repo.get!(Supermarket, id)

  # -------------------------------------------------------------------------
  # Price catalog
  # -------------------------------------------------------------------------

  @spec upsert_catalog_entry(map()) ::
          {:ok, SupermarketCatalog.t()} | {:error, Ecto.Changeset.t()}
  def upsert_catalog_entry(attrs) do
    %SupermarketCatalog{}
    |> SupermarketCatalog.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:price_cents_ars, :unit, :last_scraped_at, :updated_at]},
      conflict_target: [:supermarket_id, :ingredient_id, :price_date]
    )
  end

  @spec get_latest_price(pos_integer(), pos_integer(), Date.t()) ::
          SupermarketCatalog.t() | nil
  def get_latest_price(supermarket_id, ingredient_id, date) do
    from(c in SupermarketCatalog,
      where: c.supermarket_id == ^supermarket_id and c.ingredient_id == ^ingredient_id,
      where: c.price_date <= ^date,
      order_by: [desc: c.price_date],
      limit: 1
    )
    |> Repo.one()
  end

  @spec list_prices_for_ingredient(pos_integer()) :: [SupermarketCatalog.t()]
  def list_prices_for_ingredient(ingredient_id) do
    from(c in SupermarketCatalog,
      where: c.ingredient_id == ^ingredient_id,
      order_by: [asc: c.price_cents_ars],
      preload: [:supermarket]
    )
    |> Repo.all()
  end

  # -------------------------------------------------------------------------
  # Checkout sessions
  # -------------------------------------------------------------------------

  @spec create_checkout_session(map()) ::
          {:ok, CheckoutSession.t()} | {:error, Ecto.Changeset.t()}
  def create_checkout_session(attrs),
    do: %CheckoutSession{} |> CheckoutSession.changeset(attrs) |> Repo.insert()

  @spec update_checkout_session(CheckoutSession.t(), map()) ::
          {:ok, CheckoutSession.t()} | {:error, Ecto.Changeset.t()}
  def update_checkout_session(session, attrs),
    do: session |> CheckoutSession.changeset(attrs) |> Repo.update()

  @spec get_checkout_session!(pos_integer()) :: CheckoutSession.t()
  def get_checkout_session!(id), do: Repo.get!(CheckoutSession, id)

  @spec get_checkout_session_for_account(pos_integer(), pos_integer()) ::
          CheckoutSession.t() | nil
  def get_checkout_session_for_account(account_id, checkout_session_id) do
    from(s in CheckoutSession,
      where: s.account_id == ^account_id and s.id == ^checkout_session_id,
      limit: 1
    )
    |> Repo.one()
  end

  @spec list_checkout_sessions(pos_integer()) :: [CheckoutSession.t()]
  def list_checkout_sessions(account_id) do
    from(s in CheckoutSession,
      where: s.account_id == ^account_id,
      order_by: [desc: s.inserted_at]
    )
    |> Repo.all()
  end

  @spec list_pending_delivery_sessions(pos_integer()) :: [CheckoutSession.t()]
  def list_pending_delivery_sessions(account_id) do
    from(s in CheckoutSession,
      where: s.account_id == ^account_id and s.status == :pending_delivery,
      order_by: [asc: s.inserted_at]
    )
    |> Repo.all()
  end

  # -------------------------------------------------------------------------
  # Shopping items
  # -------------------------------------------------------------------------

  @spec create_shopping_item(map()) :: {:ok, ShoppingItem.t()} | {:error, Ecto.Changeset.t()}
  def create_shopping_item(attrs),
    do: %ShoppingItem{} |> ShoppingItem.changeset(attrs) |> Repo.insert()

  @spec upsert_shopping_item(map()) :: {:ok, ShoppingItem.t()} | {:error, Ecto.Changeset.t()}
  def upsert_shopping_item(attrs) do
    %ShoppingItem{}
    |> ShoppingItem.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:quantity_milli, :is_checked, :updated_at]},
      conflict_target: [:checkout_session_id, :ingredient_id]
    )
  end

  @spec list_shopping_items(pos_integer()) :: [ShoppingItem.t()]
  def list_shopping_items(checkout_session_id) do
    from(i in ShoppingItem,
      where: i.checkout_session_id == ^checkout_session_id,
      preload: [:ingredient],
      order_by: [asc: i.inserted_at]
    )
    |> Repo.all()
  end

  @spec update_shopping_item(ShoppingItem.t(), map()) ::
          {:ok, ShoppingItem.t()} | {:error, Ecto.Changeset.t()}
  def update_shopping_item(item, attrs),
    do: item |> ShoppingItem.changeset(attrs) |> Repo.update()

  @spec delete_shopping_item(pos_integer()) :: :ok
  def delete_shopping_item(id) do
    Repo.delete!(Repo.get!(ShoppingItem, id))
    :ok
  end

  @spec toggle_shopping_item_checked(pos_integer()) ::
          {:ok, ShoppingItem.t()} | {:error, Ecto.Changeset.t()}
  def toggle_shopping_item_checked(id) do
    item = Repo.get!(ShoppingItem, id)
    update_shopping_item(item, %{is_checked: not item.is_checked})
  end
end
