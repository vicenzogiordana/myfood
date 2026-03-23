defmodule MealPlannerApi.Persistence.Identity do
  @moduledoc """
  Bridges auth identities to persistent UUID identities used by Ecto schemas.
  """

  import Ecto.Query, warn: false

  alias MealPlannerApi.Repo
  alias MealPlannerApi.Persistence.Accounts.{Account, User}

  @spec ensure_persistent_identity(map()) ::
          {:ok, %{account_id: Ecto.UUID.t(), user_id: Ecto.UUID.t()}}
          | {:error, Ecto.Changeset.t() | :invalid_identity}
  def ensure_persistent_identity(%{id: external_user_id, account_id: external_account_id} = user)
      when is_binary(external_user_id) and is_binary(external_account_id) do
    with {:ok, account_id} <- stable_uuid("account:" <> external_account_id),
         {:ok, user_id} <- stable_uuid("user:" <> external_user_id),
         {:ok, _account} <- ensure_account(account_id, user),
         {:ok, _user} <- ensure_user(user_id, account_id, user) do
      {:ok, %{account_id: account_id, user_id: user_id}}
    end
  end

  def ensure_persistent_identity(_), do: {:error, :invalid_identity}

  defp ensure_account(account_id, user) do
    attrs = %{
      name: map_user_name(user),
      account_type: Map.get(user, :account_type, :individual),
      default_budget_cents: 0
    }

    case Repo.get(Account, account_id) do
      nil ->
        %Account{id: account_id}
        |> Account.changeset(attrs)
        |> Repo.insert()

      account ->
        account
        |> Account.changeset(attrs)
        |> Repo.update()
    end
  end

  defp ensure_user(user_id, account_id, user) do
    attrs = %{
      account_id: account_id,
      email: Map.get(user, :email, "#{user_id}@myfood.local"),
      name: map_user_name(user),
      role: :owner
    }

    case Repo.get(User, user_id) do
      nil ->
        %User{id: user_id}
        |> User.changeset(attrs)
        |> Repo.insert()

      persisted_user ->
        persisted_user
        |> User.changeset(attrs)
        |> Repo.update()
    end
  end

  defp stable_uuid(value) do
    <<a1::32, a2::16, a3::16, a4::16, a5::48, _::binary>> = :crypto.hash(:sha256, value)

    part3 = Bitwise.bor(Bitwise.band(a3, 0x0FFF), 0x4000)
    part4 = Bitwise.bor(Bitwise.band(a4, 0x3FFF), 0x8000)

    uuid =
      [
        Integer.to_string(a1, 16) |> String.pad_leading(8, "0"),
        Integer.to_string(a2, 16) |> String.pad_leading(4, "0"),
        Integer.to_string(part3, 16) |> String.pad_leading(4, "0"),
        Integer.to_string(part4, 16) |> String.pad_leading(4, "0"),
        Integer.to_string(a5, 16) |> String.pad_leading(12, "0")
      ]
      |> Enum.join("-")

    Ecto.UUID.cast(uuid)
  end

  defp map_user_name(user) do
    case Map.get(user, :name) do
      name when is_binary(name) and name != "" -> name
      _ -> "MyFood User"
    end
  end
end
