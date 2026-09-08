defmodule MealPlannerApi.Services.PlanningRequestValidator do
  @moduledoc "Validates account and participant authority before planning writes or optimization."

  alias MealPlannerApi.Persistence.Accounts.AccountMembershipQueries

  @spec validate_request(map(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, map(),
           %{account_id: Ecto.UUID.t(), actor_id: Ecto.UUID.t(), participant_ids: [Ecto.UUID.t()]}}
          | {:error, :not_a_member | :forbidden}
  def validate_request(constraints, account_id, actor_id) when is_map(constraints) do
    participants =
      Map.get(constraints, "participant_ids", Map.get(constraints, :participant_ids, [actor_id]))

    with {:ok, actor_id} <- Ecto.UUID.cast(actor_id),
         {:ok, participants} <- cast_participant_ids(participants),
         :ok <- validate_actor(account_id, actor_id),
         true <- Enum.all?(participants, &active_member?(&1, account_id)) do
      validated_constraints =
        constraints
        |> Map.delete(:participant_ids)
        |> Map.put("participant_ids", participants)

      {:ok, validated_constraints,
       %{account_id: account_id, actor_id: actor_id, participant_ids: participants}}
    else
      :error -> {:error, :forbidden}
      nil -> {:error, :not_a_member}
      false -> {:error, :forbidden}
      {:error, _} -> {:error, :forbidden}
    end
  end

  def validate_request(_, _, _), do: {:error, :forbidden}

  @spec validate_actor(Ecto.UUID.t(), Ecto.UUID.t()) :: :ok | {:error, :not_a_member}
  def validate_actor(account_id, actor_id) do
    case AccountMembershipQueries.load_active_membership(actor_id, account_id) do
      %{status: :active} -> :ok
      nil -> {:error, :not_a_member}
    end
  end

  defp active_member?(user_id, account_id),
    do:
      match?(
        %{status: :active},
        AccountMembershipQueries.load_active_membership(user_id, account_id)
      )

  defp cast_participant_ids(participants) when is_list(participants) and participants != [] do
    participants
    |> Enum.reduce_while({:ok, []}, fn participant_id, {:ok, ids} ->
      case Ecto.UUID.cast(participant_id) do
        {:ok, id} -> {:cont, {:ok, [id | ids]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, ids} -> {:ok, ids |> Enum.reverse() |> Enum.uniq()}
      :error -> :error
    end
  end

  defp cast_participant_ids(_), do: :error
end
