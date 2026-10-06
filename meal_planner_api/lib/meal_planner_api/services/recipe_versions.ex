defmodule MealPlannerApi.Services.RecipeVersions do
  @moduledoc """
  Immutable recipe publication. A successor owns a new recipe row so existing
  proposals keep their recipe identity until explicit recalculation.

  `correct/2` is an internal catalog-maintenance boundary, not an Account API or
  nutrition-review workflow. Callers must supply validated operational authority.
  """
  import Ecto.Query
  alias MealPlannerApi.Repo
  alias MealPlannerApi.Persistence.Catalog.{Recipe, RecipeVersion, RecipeIngredient, RecipeStep}

  @recipe_fields ~w(name description prep_time_minutes cook_time_minutes servings source calories_per_serving protein_g_per_serving carbs_g_per_serving fat_g_per_serving suitable_for_slots)a

  def freeze(recipe_id) do
    case Ecto.UUID.dump(recipe_id) do
      {:ok, uuid} ->
        %{rows: [[id]]} = Repo.query!("SELECT freeze_recipe_version($1::uuid)", [uuid])
        if id, do: Repo.get!(RecipeVersion, Ecto.UUID.load!(id)), else: nil

      :error ->
        nil
    end
  end

  @doc "Freezes unique recipe IDs with the publication lock, then batch-loads their versions."
  def freeze_many(recipe_ids) when is_list(recipe_ids) do
    uuids =
      recipe_ids
      |> Enum.flat_map(fn id ->
        case Ecto.UUID.dump(id) do
          {:ok, uuid} -> [uuid]
          :error -> []
        end
      end)
      |> Enum.uniq()
      |> Enum.sort()

    case uuids do
      [] ->
        %{}

      _ ->
        # Reuse the database publication boundary in stable lock order. Load in
        # a separate statement so newly inserted versions are visible as well.
        %{rows: rows} =
          Repo.query!(
            """
            SELECT freeze_recipe_version(recipe_id)
            FROM (SELECT unnest($1::uuid[]) AS recipe_id ORDER BY recipe_id) AS candidates
            """,
            [uuids]
          )

        version_ids = for [id] <- rows, not is_nil(id), do: Ecto.UUID.load!(id)

        from(v in RecipeVersion, where: v.id in ^version_ids)
        |> Repo.all()
        |> Map.new(&{&1.recipe_id, &1})
    end
  end

  def correct(recipe_id, attrs) when is_map(attrs) do
    Repo.transaction(fn ->
      recipe =
        Repo.one(from(r in Recipe, where: r.id == ^recipe_id, lock: "FOR UPDATE")) ||
          Repo.rollback(:not_found)

      if recipe.superseded_by_id, do: Repo.rollback(:already_superseded)
      previous = freeze(recipe_id)
      attrs = Map.new(attrs, fn {key, value} -> {to_string(key), value} end)

      snapshot =
        Map.merge(previous.snapshot, Map.take(attrs, Enum.map(@recipe_fields, &to_string/1)))

      recipe_attrs =
        Map.take(snapshot, Enum.map(@recipe_fields, &to_string/1))
        |> Map.put("account_id", recipe.account_id)
        |> Map.put("created_by_user_id", recipe.created_by_user_id)

      successor = insert!(Recipe.changeset(%Recipe{}, recipe_attrs))

      Enum.each(Map.get(attrs, "recipe_steps", previous.snapshot["recipe_steps"]), fn step ->
        step =
          stringify(step)
          |> Map.take(~w(step_number instructions duration_minutes))
          |> Map.put("recipe_id", successor.id)

        insert!(RecipeStep.changeset(%RecipeStep{}, step))
      end)

      Enum.each(
        Map.get(attrs, "recipe_ingredients", previous.snapshot["recipe_ingredients"]),
        fn ingredient ->
          ingredient =
            stringify(ingredient)
            |> Map.take(~w(ingredient_id quantity_milli unit))
            |> Map.put("recipe_id", successor.id)

          insert!(RecipeIngredient.changeset(%RecipeIngredient{}, ingredient))
        end
      )

      # Snapshot the newly validated associations, then insert its immutable lineage
      # in one write (never UPDATE a published version).
      successor = Repo.preload(successor, [:recipe_steps, recipe_ingredients: [:ingredient]])

      document =
        snapshot_document(
          successor,
          Map.get(attrs, "estimated_cost_cents", previous.snapshot["estimated_cost_cents"])
        )

      version =
        Repo.insert!(%RecipeVersion{
          recipe_id: successor.id,
          predecessor_id: previous.id,
          number: previous.number + 1,
          snapshot: document
        })

      Repo.update!(Ecto.Changeset.change(recipe, superseded_by_id: successor.id))
      version
    end)
  rescue
    Ecto.Query.CastError -> {:error, :not_found}
  end

  defp insert!(changeset) do
    case Repo.insert(changeset) do
      {:ok, record} -> record
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp snapshot_document(recipe, cost) do
    unless is_integer(cost) and cost >= 0, do: Repo.rollback(:invalid_estimated_cost)

    recipe
    |> Map.take([:id, :account_id | @recipe_fields])
    |> Map.put(:estimated_cost_cents, cost)
    |> Map.put(
      :recipe_steps,
      Enum.map(
        recipe.recipe_steps,
        &Map.take(&1, [:id, :step_number, :instructions, :duration_minutes])
      )
    )
    |> Map.put(
      :recipe_ingredients,
      Enum.map(recipe.recipe_ingredients, fn item ->
        item
        |> Map.take([:id, :ingredient_id, :quantity_milli, :unit])
        |> Map.put(:ingredient, Map.take(item.ingredient, [:id, :name]))
      end)
    )
    |> Jason.encode!()
    |> Jason.decode!()
  end

  defp stringify(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  # Decode only known keys/units; never create atoms from stored or user input.
  def recipe_for_meal(%{recipe_snapshot: snapshot}) when is_map(snapshot), do: decode(snapshot)
  def recipe_for_meal(%{recipe: recipe}), do: recipe
  def recipe_for_meal(_), do: nil

  def decode(snapshot) do
    base =
      Map.new(
        [:id, :account_id, :estimated_cost_cents | @recipe_fields],
        &{&1, snapshot[to_string(&1)]}
      )

    quantity = snapshot["selected_quantity"] || 1

    base
    |> Map.put(
      :recipe_steps,
      Enum.map(snapshot["recipe_steps"] || [], fn step ->
        Map.new([:id, :step_number, :instructions, :duration_minutes], &{&1, step[to_string(&1)]})
      end)
    )
    |> Map.put(
      :recipe_ingredients,
      Enum.map(snapshot["recipe_ingredients"] || [], fn item ->
        {:ok, unit} = Ecto.Type.cast(RecipeIngredient.__schema__(:type, :unit), item["unit"])

        %{
          id: item["id"],
          ingredient_id: item["ingredient_id"],
          unit: unit,
          quantity_milli: item["quantity_milli"] * quantity,
          ingredient: %{id: item["ingredient"]["id"], name: item["ingredient"]["name"]}
        }
      end)
    )
  end
end
