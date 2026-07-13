defmodule MealPlannerApi.Persistence.Accounts.AccountMembershipQueries do
  @moduledoc """
  Single source of truth for the "load the real membership" query used
  by every current-membership resolution path (Phase A — Tenancy
  Refactor).

  Before this module existed, `MealPlannerApiWeb.Plugs.
  LoadCurrentMembership`, `MealPlannerApiWeb.Plugs.
  LoadCurrentMembershipSocket`, and `MealPlannerApi.AccountsMembership.
  current_membership/2` each independently re-implemented the same two
  lookups (legacy `access` token → `(user_id, account_id)`; `access_v2`
  token → `membership_id`) and had already drifted (one preloaded
  `:account`, the others did not). All three now delegate here.

  `preload` lets each caller keep its own genuinely-needed association
  loading instead of silently gaining or losing a preload.
  """

  import Ecto.Query, warn: false

  alias MealPlannerApi.Persistence.Accounts.AccountMembership
  alias MealPlannerApi.Repo

  @doc """
  Loads the real, `:active` `AccountMembership` row for
  `(user_id, account_id)` — the legacy `access` (v1) token path.

  Returns `nil` when `account_id` is not a valid UUID or no matching
  row exists.
  """
  @spec load_active_membership(Ecto.UUID.t(), Ecto.UUID.t() | binary(), keyword()) ::
          AccountMembership.t() | nil
  def load_active_membership(user_id, account_id, opts \\ []) do
    preload = Keyword.get(opts, :preload, [])

    case Ecto.UUID.cast(account_id) do
      {:ok, account_uuid} ->
        AccountMembership
        |> Repo.get_by(user_id: user_id, account_id: account_uuid, status: :active)
        |> maybe_preload(preload)

      :error ->
        nil
    end
  end

  @doc """
  Loads the `AccountMembership` row identified by its primary key — the
  `access_v2` token path.

  Deliberately does NOT filter by `status` (unlike
  `load_active_membership/3`'s legacy path). This is intentional, not
  an oversight (tenancy debt cleanup item 2 investigated adding a
  blanket `status: :active` filter here and found it breaks Phoenix
  Channel joins — see `MealPlannerApiWeb.Plugs.
  LoadCurrentMembershipSocket` moduledoc and each channel's `join/3`,
  e.g. `MealPlannerApiWeb.CalendarChannel`): channels re-fetch the
  membership via `LoadCurrentMembershipSocket.membership_from_socket/1`
  inside `join/3` and explicitly check `membership.status != :active`
  themselves so they can return a specific `{:error, %{reason:
  "forbidden"}}` at JOIN time, while the socket CONNECT itself must
  still succeed for a non-`:active` (e.g. `:invited`) membership (Q8 —
  design §7; regression-locked by the "invited (non-active) membership
  join is rejected" tests in each channel's test file).

  Callers that DO need active-only, fail-closed semantics with no
  status-aware caller downstream (the HTTP plug's `access_v2` branch,
  `AccountsMembership.load_v2_membership/1`) must check
  `membership.status == :active` themselves on the returned row —
  see those modules.

  Returns `nil` when `membership_id` is not a valid UUID or no row
  exists at all.
  """
  @spec load_membership_by_id(String.t(), keyword()) :: AccountMembership.t() | nil
  def load_membership_by_id(membership_id, opts \\ []) when is_binary(membership_id) do
    preload = Keyword.get(opts, :preload, [])

    case Ecto.UUID.cast(membership_id) do
      {:ok, uuid} ->
        uuid
        |> by_id_query()
        |> Repo.one()
        |> maybe_preload(preload)

      :error ->
        nil
    end
  end

  defp by_id_query(uuid) do
    from(m in AccountMembership, where: m.id == ^uuid)
  end

  defp maybe_preload(nil, _preload), do: nil
  defp maybe_preload(membership, []), do: membership
  defp maybe_preload(membership, preload), do: Repo.preload(membership, preload)
end
