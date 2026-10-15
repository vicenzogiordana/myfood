defmodule MealPlannerApi.PlanningAgent.Consent do
  @moduledoc """
  Explicit consent before a Member's Household data is first sent to an
  external AI provider (spec #93, user story 5). Recording it is a human-only
  action; the agent can never grant it.
  """

  import Ecto.Query

  alias MealPlannerApi.Persistence.Planning.AiProcessingConsent
  alias MealPlannerApi.Repo

  @doc "Whether the User has consented to external AI processing in the Household."
  @spec granted?(Ecto.UUID.t(), Ecto.UUID.t()) :: boolean()
  def granted?(account_id, user_id) do
    Repo.exists?(
      from(c in AiProcessingConsent, where: c.account_id == ^account_id and c.user_id == ^user_id)
    )
  end

  @doc "Records the User's consent. Idempotent."
  @spec record(Ecto.UUID.t(), Ecto.UUID.t()) :: :ok | {:error, Ecto.Changeset.t()}
  def record(account_id, user_id) do
    %AiProcessingConsent{}
    |> AiProcessingConsent.changeset(%{
      account_id: account_id,
      user_id: user_id,
      granted_at: DateTime.utc_now()
    })
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:account_id, :user_id])
    |> case do
      {:ok, _} -> :ok
      {:error, changeset} -> {:error, changeset}
    end
  end
end
