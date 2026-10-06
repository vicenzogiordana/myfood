defmodule MealPlannerApi.CartFixtures do
  @moduledoc false
  import Ecto.Query
  alias MealPlannerApi.Generation.ServerTestFixtures, as: Fixtures
  alias MealPlannerApi.Persistence.{Catalog, Planning, Shopping}
  alias MealPlannerApi.Persistence.Accounts.{Account, AccountMembership, User}
  alias MealPlannerApi.Persistence.Inventory.{InventoryItem, InventoryMutationEvent}
  alias MealPlannerApi.Persistence.Shopping.{CheckoutSession, ShoppingItem}
  alias MealPlannerApi.Repo

  def fixture do
    {:ok, f} =
      Repo.transaction(fn ->
        suffix = Ecto.UUID.generate()
        account = Fixtures.insert_account("Cart lifecycle #{suffix}")
        now = DateTime.utc_now()

        account =
          account
          |> Account.changeset(%{trial_started_at: now, trial_ends_at: DateTime.add(now, 86400)})
          |> Repo.update!()

        owner = Fixtures.insert_user_with_membership(account, "cart-owner-#{suffix}@example.com")

        member =
          Fixtures.insert_user_with_membership(
            account,
            "cart-member-#{suffix}@example.com",
            :member
          )

        ingredient = Fixtures.insert_ingredient("Cart ingredient #{suffix}")

        recipe =
          Fixtures.insert_recipe("Cart recipe #{suffix}",
            account_id: account.id,
            user_id: owner.id
          )

        {:ok, meal} =
          Planning.schedule_meal(%{
            account_id: account.id,
            recipe_id: recipe.id,
            date: Date.utc_today(),
            slot: :dinner
          })

        items =
          for quantity <- [1000, 500] do
            {:ok, item} =
              Shopping.create_shopping_item(%{
                account_id: account.id,
                scheduled_meal_id: meal.id,
                planned_date: meal.date,
                ingredient_id: ingredient.id,
                unit: :g,
                quantity_milli: quantity,
                status: :pending
              })

            item
          end

        %{
          account: account,
          owner: owner,
          member: member,
          ingredient: ingredient,
          recipe: recipe,
          meal: meal,
          items: items,
          actor: %{id: owner.id, account_id: account.id},
          other: %{id: member.id, account_id: account.id}
        }
      end)

    f
  end

  def payload(cart, quantity \\ 300, type \\ "physical") do
    %{
      "session_id" => cart.session_id,
      "checkout_type" => type,
      "items" =>
        Enum.map(cart.reservations, fn line ->
          %{
            "item_id" => line.item_id,
            "reservation_token" => line.reservation_token,
            "quantity_milli" => quantity,
            "total_cents" => if(quantity == 0, do: 0, else: 250)
          }
        end)
    }
  end

  def reserve!(f, actor \\ nil) do
    {:ok, cart} = MealPlannerApi.Cart.reserve(actor || f.actor, Enum.map(f.items, & &1.id))
    cart
  end

  def expire!(cart) do
    Repo.get!(CheckoutSession, cart.session_id)
    |> CheckoutSession.changeset(%{lease_expires_at: DateTime.add(DateTime.utc_now(), -1)})
    |> Repo.update!()
  end

  def events(f),
    do:
      Repo.all(
        from(e in InventoryMutationEvent, where: e.account_id == ^f.account.id, order_by: e.id)
      )

  def stock(f),
    do: Repo.all(from(i in InventoryItem, where: i.account_id == ^f.account.id, order_by: i.id))

  def lines(f),
    do: Repo.all(from(i in ShoppingItem, where: i.account_id == ^f.account.id, order_by: i.id))

  def cleanup(f) do
    Repo.transaction(fn ->
      Repo.delete_all(from(e in InventoryMutationEvent, where: e.account_id == ^f.account.id))
      Repo.delete_all(from(i in InventoryItem, where: i.account_id == ^f.account.id))
      Repo.delete_all(from(i in ShoppingItem, where: i.account_id == ^f.account.id))
      Repo.delete_all(from(c in CheckoutSession, where: c.account_id == ^f.account.id))
      Repo.delete_all(from(m in Planning.ScheduledMeal, where: m.account_id == ^f.account.id))
      Repo.delete_all(from(r in Catalog.Recipe, where: r.account_id == ^f.account.id))
      Repo.delete_all(from(m in AccountMembership, where: m.account_id == ^f.account.id))
      Repo.delete_all(from(u in User, where: u.id in ^[f.owner.id, f.member.id]))
      Repo.delete_all(from(a in Account, where: a.id == ^f.account.id))
      Repo.delete_all(from(i in Catalog.Ingredient, where: i.id == ^f.ingredient.id))
    end)
  end
end
