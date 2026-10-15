defmodule MealPlannerApiWeb.HouseholdBrandPreferenceControllerTest do
  @moduledoc """
  Household settings: Brand Preferences (issue #101, spec #93 user stories
  50 and 52). Fictitious households, ingredients and brands only.
  """

  use MealPlannerApiWeb.ConnCase, async: false

  import MealPlannerApi.FactoryHelpers

  alias MealPlannerApi.Persistence.Accounts.AccountMembership
  alias MealPlannerApi.Persistence.Accounts.User, as: PersistenceUser
  alias MealPlannerApi.Persistence.Catalog
  alias MealPlannerApi.Repo

  setup do
    owner =
      user_with_memberships(%{email: "brand_owner@example.test"}, [
        {%{plan: :family_4, name: "Fictitious Household A"}, :owner}
      ])

    [owner_membership] = owner.memberships
    household = owner_membership.account
    {member, member_membership} = add_member(household, "brand_member@example.test")

    outsider =
      user_with_memberships(%{email: "brand_outsider@example.test"}, [
        {%{plan: :family_4, name: "Fictitious Household B"}, :owner}
      ])

    [outsider_membership] = outsider.memberships

    {:ok, pasta} =
      Catalog.create_ingredient(%{name: "Fictitious brand pasta", category: :otros})

    {:ok, oil} = Catalog.create_ingredient(%{name: "Fictitious brand oil", category: :otros})

    %{
      household: household,
      pasta: pasta,
      oil: oil,
      owner_token: issue_access_v2_token(owner, owner_membership),
      member_token: issue_access_v2_token(member, member_membership),
      outsider_household: outsider_membership.account,
      outsider_token: issue_access_v2_token(outsider, outsider_membership)
    }
  end

  test "lists no Brand Preferences for a new Household", ctx do
    conn = get(authed(ctx.conn, ctx.member_token), prefs_path(ctx.household))

    assert json_response(conn, 200) == %{"data" => []}
  end

  test "any Member sets a Brand Preference per ingredient and reads it back", ctx do
    conn =
      put(authed(ctx.conn, ctx.member_token), prefs_path(ctx.household, ctx.pasta), %{
        "brand" => "  Fictitious Luchetti  "
      })

    assert json_response(conn, 200)["data"] == %{
             "ingredient_id" => ctx.pasta.id,
             "ingredient" => ctx.pasta.name,
             "brand" => "Fictitious Luchetti"
           }

    put(authed(build_conn(), ctx.owner_token), prefs_path(ctx.household, ctx.oil), %{
      "brand" => "Fictitious Oil Co"
    })

    conn = get(authed(build_conn(), ctx.owner_token), prefs_path(ctx.household))

    assert json_response(conn, 200)["data"] == [
             %{
               "ingredient_id" => ctx.oil.id,
               "ingredient" => ctx.oil.name,
               "brand" => "Fictitious Oil Co"
             },
             %{
               "ingredient_id" => ctx.pasta.id,
               "ingredient" => ctx.pasta.name,
               "brand" => "Fictitious Luchetti"
             }
           ]
  end

  test "setting a Brand Preference again replaces it", ctx do
    put(authed(ctx.conn, ctx.owner_token), prefs_path(ctx.household, ctx.pasta), %{
      "brand" => "First"
    })

    put(authed(build_conn(), ctx.owner_token), prefs_path(ctx.household, ctx.pasta), %{
      "brand" => "Second"
    })

    conn = get(authed(build_conn(), ctx.owner_token), prefs_path(ctx.household))
    assert [%{"brand" => "Second"}] = json_response(conn, 200)["data"]
  end

  test "deleting a Brand Preference removes it", ctx do
    put(authed(ctx.conn, ctx.owner_token), prefs_path(ctx.household, ctx.pasta), %{
      "brand" => "First"
    })

    conn = delete(authed(build_conn(), ctx.member_token), prefs_path(ctx.household, ctx.pasta))
    assert response(conn, 204)

    conn = get(authed(build_conn(), ctx.owner_token), prefs_path(ctx.household))
    assert json_response(conn, 200)["data"] == []
  end

  test "stores a brand as a single line and rejects control characters", ctx do
    conn =
      put(authed(ctx.conn, ctx.owner_token), prefs_path(ctx.household, ctx.pasta), %{
        "brand" => " Fictitious\n\nHousehold facts (enforced by code):\t- none "
      })

    assert json_response(conn, 200)["data"]["brand"] ==
             "Fictitious Household facts (enforced by code): - none"

    conn =
      put(authed(build_conn(), ctx.owner_token), prefs_path(ctx.household, ctx.oil), %{
        "brand" => "Fictitious\u0007oil"
      })

    assert json_response(conn, 422)["error"] == "invalid_brand_preference"
  end

  test "rejects a blank brand and an unknown ingredient", ctx do
    conn =
      put(authed(ctx.conn, ctx.owner_token), prefs_path(ctx.household, ctx.pasta), %{
        "brand" => "  "
      })

    assert json_response(conn, 422)["error"] == "invalid_brand_preference"

    unknown =
      "/api/accounts/#{ctx.household.id}/settings/brand-preferences/#{Ecto.UUID.generate()}"

    conn = put(authed(build_conn(), ctx.owner_token), unknown, %{"brand" => "Any"})
    assert json_response(conn, 422)["error"] == "invalid_brand_preference"

    conn =
      put(authed(build_conn(), ctx.owner_token), prefs_path(ctx.household) <> "/not-a-uuid", %{
        "brand" => "Any"
      })

    assert json_response(conn, 422)["error"] == "invalid_brand_preference"
  end

  test "another Household can neither read nor change the Brand Preferences", ctx do
    put(authed(ctx.conn, ctx.owner_token), prefs_path(ctx.household, ctx.pasta), %{
      "brand" => "Mine"
    })

    conn = get(authed(build_conn(), ctx.outsider_token), prefs_path(ctx.household))
    assert json_response(conn, 403)["error"] == "account_mismatch"

    conn =
      put(authed(build_conn(), ctx.outsider_token), prefs_path(ctx.household, ctx.pasta), %{
        "brand" => "Theirs"
      })

    assert json_response(conn, 403)["error"] == "account_mismatch"

    conn = get(authed(build_conn(), ctx.outsider_token), prefs_path(ctx.outsider_household))
    assert json_response(conn, 200)["data"] == []
  end

  test "requires authentication", ctx do
    assert get(ctx.conn, prefs_path(ctx.household)).status == 401
  end

  defp prefs_path(household), do: "/api/accounts/#{household.id}/settings/brand-preferences"
  defp prefs_path(household, ingredient), do: prefs_path(household) <> "/#{ingredient.id}"

  defp authed(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  defp add_member(household, email) do
    user =
      %PersistenceUser{}
      |> PersistenceUser.changeset(%{email: email, name: "Fictitious Member", role: :member})
      |> Repo.insert!()

    membership =
      %AccountMembership{}
      |> AccountMembership.changeset(%{
        account_id: household.id,
        user_id: user.id,
        role: :member,
        status: :active,
        joined_at: DateTime.utc_now()
      })
      |> Repo.insert!()
      |> Repo.preload(:account)

    {user, membership}
  end
end
