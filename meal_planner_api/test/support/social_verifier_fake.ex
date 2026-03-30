defmodule MealPlannerApi.Auth.SocialVerifierFake do
  @behaviour MealPlannerApi.Auth.SocialVerifier

  @impl true
  def verify(_provider, _id_token, _opts) do
    case Process.get({__MODULE__, :response}) do
      {:ok, _identity} = ok -> ok
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_social_token}
    end
  end
end
