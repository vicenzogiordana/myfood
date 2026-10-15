defmodule MealPlannerApi.Persistence.Catalog do
  @moduledoc "Persistence helpers for ingredients, recipes and cost cache."

  import Ecto.Query, warn: false

  alias MealPlannerApi.Repo

  alias MealPlannerApi.Persistence.Catalog.{
    Ingredient,
    IngredientTag,
    Recipe,
    RecipeDailyCost,
    RecipeIngredient,
    RecipeStep
  }

  alias MealPlannerApi.Persistence.Shopping.RecipePrice
  alias MealPlannerApi.Planning.Restrictions

  def create_ingredient(attrs), do: %Ingredient{} |> Ingredient.changeset(attrs) |> Repo.insert()

  def upsert_ingredient_by_name(attrs) do
    %Ingredient{}
    |> Ingredient.changeset(attrs)
    |> Repo.insert(
      on_conflict:
        {:replace,
         [
           :category,
           :sku_reference,
           :calories_per_100,
           :protein_g_per_100,
           :carbs_g_per_100,
           :fat_g_per_100,
           :updated_at
         ]},
      conflict_target: [:name]
    )
  end

  def list_ingredients, do: Repo.all(Ingredient)

  def create_recipe(attrs), do: %Recipe{} |> Recipe.changeset(attrs) |> Repo.insert()

  def get_recipe!(id), do: Repo.get!(Recipe, id)

  def get_recipe_with_details!(id) do
    Recipe
    |> Repo.get!(id)
    |> Repo.preload([:recipe_steps, :recipe_ingredients, :daily_costs])
  end

  def add_recipe_step(attrs), do: %RecipeStep{} |> RecipeStep.changeset(attrs) |> Repo.insert()

  def add_recipe_ingredient(attrs),
    do: %RecipeIngredient{} |> RecipeIngredient.changeset(attrs) |> Repo.insert()

  # ---------------------------------------------------------------------------
  # Ingredient Tags
  # ---------------------------------------------------------------------------

  @doc """
  Records a reviewed Ingredient Tag. Promotes an existing suggestion for the
  same tag to reviewed.
  """
  @spec tag_ingredient(Ecto.UUID.t(), atom() | String.t()) ::
          {:ok, IngredientTag.t()} | {:error, :unknown_tag | Ecto.Changeset.t()}
  def tag_ingredient(ingredient_id, tag) do
    with {:ok, tag} <- Restrictions.cast_tag(tag) do
      now = DateTime.utc_now()

      %IngredientTag{}
      |> IngredientTag.changeset(%{
        ingredient_id: ingredient_id,
        tag: tag,
        status: :reviewed,
        reviewed_at: now
      })
      |> Repo.insert(
        on_conflict: [set: [status: :reviewed, reviewed_at: now, updated_at: now]],
        conflict_target: [:ingredient_id, :tag],
        returning: true
      )
    end
  end

  @doc """
  Stores tag suggestions (for example from AI) as unreviewed. A suggestion
  never downgrades a tag that is already reviewed. Returns the suggestions that
  are still pending review for the given tags.
  """
  @spec suggest_ingredient_tags(Ecto.UUID.t(), [atom() | String.t()]) ::
          {:ok, [IngredientTag.t()]} | {:error, :unknown_tag | Ecto.Changeset.t()}
  def suggest_ingredient_tags(ingredient_id, tags) when is_list(tags) do
    with {:ok, tags} <- cast_tags(tags) do
      Repo.transaction(fn ->
        Enum.each(tags, fn tag ->
          %IngredientTag{}
          |> IngredientTag.changeset(%{
            ingredient_id: ingredient_id,
            tag: tag,
            status: :suggested
          })
          |> Repo.insert(on_conflict: :nothing, conflict_target: [:ingredient_id, :tag])
          |> case do
            {:ok, _} -> :ok
            {:error, changeset} -> Repo.rollback(changeset)
          end
        end)

        from(t in IngredientTag,
          where: t.ingredient_id == ^ingredient_id and t.tag in ^tags and t.status == :suggested,
          order_by: t.tag
        )
        |> Repo.all()
      end)
    end
  end

  @doc "A reviewer accepts a pending suggestion, which then counts as reviewed."
  @spec accept_tag_suggestion(Ecto.UUID.t(), atom() | String.t()) ::
          {:ok, IngredientTag.t()} | {:error, :unknown_tag | :not_found}
  def accept_tag_suggestion(ingredient_id, tag) do
    with {:ok, tag} <- Restrictions.cast_tag(tag) do
      now = DateTime.utc_now()

      from(t in IngredientTag,
        where: t.ingredient_id == ^ingredient_id and t.tag == ^tag and t.status == :suggested,
        select: t
      )
      |> Repo.update_all(set: [status: :reviewed, reviewed_at: now, updated_at: now])
      |> case do
        {1, [accepted]} -> {:ok, accepted}
        {0, []} -> {:error, :not_found}
      end
    end
  end

  @doc "Reviewed Ingredient Tags of one Ingredient."
  @spec reviewed_tags(Ecto.UUID.t()) :: MapSet.t(atom())
  def reviewed_tags(ingredient_id), do: tags_with_status(ingredient_id, :reviewed)

  @doc "Ingredient Tags of one Ingredient still waiting for review."
  @spec suggested_tags(Ecto.UUID.t()) :: MapSet.t(atom())
  def suggested_tags(ingredient_id), do: tags_with_status(ingredient_id, :suggested)

  @doc """
  Reviewed Ingredient Tags of every ingredient of the given recipes, as
  `%{recipe_id => %{ingredient_id => MapSet.t(tag)}}`. Ingredients without
  reviewed tags are omitted; suggestions are never included.
  """
  @spec reviewed_tags_by_recipe([Ecto.UUID.t()]) :: %{
          Ecto.UUID.t() => %{Ecto.UUID.t() => MapSet.t(atom())}
        }
  def reviewed_tags_by_recipe(recipe_ids) when is_list(recipe_ids) do
    from(ri in RecipeIngredient,
      join: t in IngredientTag,
      on: t.ingredient_id == ri.ingredient_id and t.status == :reviewed,
      where: ri.recipe_id in ^Enum.uniq(recipe_ids),
      distinct: true,
      select: {ri.recipe_id, ri.ingredient_id, t.tag}
    )
    |> Repo.all()
    |> Enum.reduce(%{}, fn {recipe_id, ingredient_id, tag}, acc ->
      Map.update(acc, recipe_id, %{ingredient_id => MapSet.new([tag])}, fn by_ingredient ->
        Map.update(by_ingredient, ingredient_id, MapSet.new([tag]), &MapSet.put(&1, tag))
      end)
    end)
  end

  defp tags_with_status(ingredient_id, status) do
    from(t in IngredientTag,
      where: t.ingredient_id == ^ingredient_id and t.status == ^status,
      select: t.tag
    )
    |> Repo.all()
    |> MapSet.new()
  end

  defp cast_tags(tags) do
    Enum.reduce_while(tags, {:ok, []}, fn tag, {:ok, acc} ->
      case Restrictions.cast_tag(tag) do
        {:ok, tag} -> {:cont, {:ok, [tag | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, acc |> Enum.reverse() |> Enum.uniq()}
      error -> error
    end
  end

  def upsert_recipe_daily_cost(attrs) do
    %RecipeDailyCost{}
    |> RecipeDailyCost.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:total_cents_ars, :updated_at]},
      conflict_target: [:recipe_id, :supermarket_id, :date]
    )
  end

  def recipes_for_slot(account_id, slot) do
    slot_str = if is_atom(slot), do: Atom.to_string(slot), else: slot

    from(r in Recipe,
      where: is_nil(r.account_id) or r.account_id == ^account_id,
      where: is_nil(r.superseded_by_id),
      where: ^slot_str in r.suitable_for_slots
    )
    |> Repo.all()
  end

  @doc """
  Lists all recipes with their recipe_prices and ingredients preloaded.
  Used by PriceService to build the optimizer slot list.
  """
  @spec list_recipes_with_prices_and_ingredients() :: [Recipe.t()]
  def list_recipes_with_prices_and_ingredients do
    from(r in Recipe,
      left_join: rp in RecipePrice,
      on: rp.recipe_id == r.id,
      left_join: ri in assoc(r, :recipe_ingredients),
      left_join: i in assoc(ri, :ingredient),
      preload: [recipe_price: rp, recipe_ingredients: {ri, ingredient: i}]
    )
    |> Repo.all()
  end
end
