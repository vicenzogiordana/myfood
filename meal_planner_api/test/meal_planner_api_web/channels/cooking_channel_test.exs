defmodule MealPlannerApiWeb.CookingChannelTest do
  use MealPlannerApiWeb.ChannelCase, async: false

  alias MealPlannerApi.Accounts
  alias MealPlannerApi.Auth.Guardian
  alias MealPlannerApi.Persistence.Catalog
  alias MealPlannerApi.Persistence.Identity
  alias MealPlannerApi.Persistence.Planning
  alias MealPlannerApiWeb.UserSocket

  @tag :skip
  test "ask_assistant streams contextual chunks" do
    {:ok, user, account, token} = issue_identity_and_token("u_cook_chan", "acct_cook_chan")

    {:ok, %{account_id: account_id, user_id: user_id}} =
      Identity.ensure_persistent_identity(%{
        id: user.id,
        account_id: account.id,
        account_type: :group
      })

    {:ok, ingredient} =
      Catalog.upsert_ingredient_by_name(%{
        name: "Ajo Test Cooking Channel",
        category: :verduras,
        calories_per_100: 18,
        protein_g_per_100: Decimal.new("0.9"),
        carbs_g_per_100: Decimal.new("3.9"),
        fat_g_per_100: Decimal.new("0.2")
      })

    {:ok, recipe} =
      Catalog.create_recipe(%{
        account_id: account_id,
        created_by_user_id: user_id,
        name: "Salsa canal",
        source: :user_created,
        servings: 2,
        suitable_for_slots: [:lunch]
      })

    {:ok, step} =
      Catalog.add_recipe_step(%{
        recipe_id: recipe.id,
        step_number: 1,
        instructions: "Cocinar salsa lento",
        duration_minutes: 10
      })

    {:ok, _recipe_ingredient} =
      Catalog.add_recipe_ingredient(%{
        recipe_id: recipe.id,
        ingredient_id: ingredient.id,
        quantity_milli: 50,
        unit: :g
      })

    {:ok, meal} =
      Planning.schedule_meal(%{
        account_id: account_id,
        date: ~D[2026-03-24],
        slot: :lunch,
        recipe_id: recipe.id,
        is_cooked: false
      })

    {:ok, start} = MealPlannerApi.CookingAssistant.start_session(user, meal.id)
    session_id = start.session_id

    {:ok, _} =
      MealPlannerApi.CookingAssistant.track_step(user, session_id, step.id, :started, %{
        "view" => "chat"
      })

    {:ok, socket} = connect(UserSocket, %{"token" => token})

    topic = "cooking:#{account.id}:#{session_id}"
    {:ok, _reply, socket} = subscribe_and_join(socket, MealPlannerApiWeb.CookingChannel, topic)

    ref =
      push(socket, "ask_assistant", %{
        "request_id" => "cook_req_1",
        "message" => "La salsa la cocino bien lento no?",
        "content_type" => "speech_transcript"
      })

    assert_broadcast("assistant_typing", %{request_id: "cook_req_1"})
    assert_broadcast("assistant_chunk", %{request_id: "cook_req_1"})
    assert_broadcast("assistant_finished", %{request_id: "cook_req_1"})
    assert_reply(ref, :ok, %{request_id: "cook_req_1", content_type: "text"})
  end

  defp issue_identity_and_token(user_id, account_id) do
    with {:ok, %{user: user, account: account}} <-
           Accounts.issue_mock_identity(%{"user_id" => user_id, "account_id" => account_id}),
         {:ok, token, _claims} <-
           Guardian.encode_and_sign(user, Accounts.claims_for(user, account),
             token_type: "access"
           ) do
      {:ok, user, account, token}
    end
  end
end
