defmodule MealPlannerApiWeb.Router do
  use MealPlannerApiWeb, :router

  pipeline :api do
    plug(:accepts, ["json"])
  end

  pipeline :auth do
    plug(MealPlannerApiWeb.AuthPipeline)
  end

  scope "/api", MealPlannerApiWeb do
    pipe_through(:api)

    post("/auth/social", AuthController, :social)
    post("/auth/password", AuthController, :password)
    post("/billing/revenuecat/webhook", RevenuecatController, :webhook)
  end

  scope "/api", MealPlannerApiWeb do
    pipe_through([:api, :auth])

    get("/me", AccountsController, :me)
    get("/account/context", AccountsController, :context)
    get("/calendar", CalendarController, :index)
    get("/planning/weekly", PlanningController, :weekly)
    post("/planning/confirm", PlanningController, :confirm)
    get("/planning/favorites", PlanningChatController, :favorites)
    post("/planning/chat", PlanningChatController, :create)
    put("/planning/slots/favorite", PlanningController, :toggle_slot_favorite)
    post("/planning/proposals/:proposal_id/confirm", PlanningChatController, :confirm)
    post("/planning/proposals/:proposal_id/reject", PlanningChatController, :reject)

    post("/cooking/start", CookingController, :start)
    get("/cooking/sessions/:session_id", CookingController, :show)
    post("/cooking/sessions/:session_id/step", CookingController, :step)
    post("/cooking/sessions/:session_id/finish", CookingController, :finish)
    post("/cooking/sessions/:session_id/ask", CookingController, :ask)

    get("/shopping-list", ShoppingController, :index)
    post("/shopping-items/mark-cart", ShoppingController, :mark_cart)
    post("/shopping-items/assign-supermarket", ShoppingController, :assign_supermarket)
    post("/checkout/confirm", ShoppingController, :confirm_checkout)

    post(
      "/checkout/sessions/:checkout_session_id/delivered",
      ShoppingController,
      :confirm_delivery
    )

    get("/inventory", InventoryController, :index)
    post("/inventory/items/add-extra", InventoryController, :add_extra)
    post("/inventory/items/:item_id/quantity", InventoryController, :update_quantity)
    post("/inventory/items/:item_id/dispose", InventoryController, :dispose)
    post("/inventory/voice/preview", InventoryController, :voice_preview)
    post("/inventory/voice/apply", InventoryController, :voice_apply)
    post("/planning/rescue", InventoryController, :rescue_plan)
    post("/billing/revenuecat/sync", RevenuecatController, :sync)
  end
end
