defmodule MealPlannerApi.AI.GeminiClientTest do
  @moduledoc """
  Regression coverage for bug #2 (see `MealPlannerApi.AITest` for bug #1):
  `get_in(opts, [:user, :account_id])` requires every level of the path to
  implement the `Access` behaviour. Plain Ecto structs (like
  `MealPlannerApi.Persistence.Accounts.User`, the real struct every caller
  passes once bug #1 is fixed) do NOT implement `Access` and raise at
  runtime. `account_id` extraction happens synchronously (before
  `Task.start/1`), so this crash is directly observable without mocking
  the Gemini HTTP call.
  """
  use ExUnit.Case, async: true

  alias MealPlannerApi.AI.GeminiClient
  alias MealPlannerApi.Persistence.Accounts.User, as: PersistenceUser

  describe "stream_chat_completion/3" do
    test "extracts account_id from a real Persistence.Accounts.User struct without raising" do
      user = %PersistenceUser{id: "u_gemini_test", account_id: "acct_gemini_test"}

      assert :ok =
               GeminiClient.stream_chat_completion("ai_chat:gemini_room", "hola", user: user)
    end
  end
end
