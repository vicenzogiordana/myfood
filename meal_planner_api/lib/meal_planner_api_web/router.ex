defmodule MealPlannerApiWeb.Router do
  use MealPlannerApiWeb, :router

  pipeline :api do
    plug(:accepts, ["json"])
  end

  pipeline :auth do
    plug(MealPlannerApiWeb.AuthPipeline)
  end

  # Phase A — Tenancy Refactor (PR 3a task 3.1, formalized in task 3.7):
  # rejects `:account_id`-bearing routes when the URL id does not match
  # `current_membership.account_id` (403 account_mismatch).
  pipeline :enforce_account_scope do
    plug(MealPlannerApiWeb.Plugs.EnforceAccountScope)
  end

  scope "/api", MealPlannerApiWeb do
    pipe_through(:api)

    # Auth endpoints (no auth required)
    post("/auth/social", AuthController, :social)
    post("/auth/password", AuthController, :password)
    # Route aliases for frontend compatibility (G1-G5)
    post("/auth/login", AuthController, :password)
    post("/auth/register", AuthController, :password)
    post("/auth/google", AuthController, :social)
    post("/auth/facebook", AuthController, :social)
    post("/auth/apple", AuthController, :social)
    # Refresh token (G6)
    post("/auth/refresh", AuthController, :refresh)
    # Logout (G7)
    post("/auth/logout", AuthController, :logout)

    post("/billing/revenuecat/webhook", RevenuecatController, :webhook)

    # Phase A — Tenancy Refactor (PR 3a task 3.4): deliberately NOT behind
    # `:auth` — the "new User accepts" case has no account/token yet
    # (spec `invite-and-accept.md` §"New User accepts"). The controller
    # manually decodes an optional Authorization header for the
    # "existing User accepts" case instead of relying on the pipeline.
    post("/invites/:token/accept", InviteController, :accept)
  end

  scope "/api", MealPlannerApiWeb do
    pipe_through([:api, :auth])

    # User endpoints (auth required)
    get("/me", AccountsController, :me)
    # Alias for frontend (G8)
    get("/auth/me", AccountsController, :me)
    get("/account/context", AccountsController, :context)
    get("/calendar", CalendarController, :index)
    get("/calendar/slot", CalendarController, :show_slot)
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

    # Phase A — Tenancy Refactor (PR 3a task 3.5): no `:account_id` in the
    # URL, so `:enforce_account_scope` does not apply (design §5.2).
    post("/auth/switch-account", AccountLifecycleController, :switch_account)
  end

  # Phase A — Tenancy Refactor (PR 3a): membership / invite / lifecycle
  # endpoints scoped to an Account via the URL (design §5.2, §6).
  scope "/api/accounts/:account_id", MealPlannerApiWeb do
    pipe_through([:api, :auth, :enforce_account_scope])

    get("/memberships", MembershipController, :index)
    delete("/memberships/:user_id", MembershipController, :delete)
    post("/invites", InviteController, :create)
    post("/leave", AccountLifecycleController, :leave)
  end
end
