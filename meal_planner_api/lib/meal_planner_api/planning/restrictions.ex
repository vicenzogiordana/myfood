defmodule MealPlannerApi.Planning.Restrictions do
  @moduledoc """
  Ingredient Tag vocabulary and the fixed mapping from a Restriction to the set
  of Ingredient Tags it forbids.

  A Restriction is either `{:diet, diet}` or `{:allergy, tag}`:

    * `{:diet, :omnivore}` forbids nothing
    * `{:diet, :vegetarian}` forbids meat and fish
    * `{:diet, :pescatarian}` forbids meat
    * `{:diet, :vegan}` forbids every animal product (meat and fish included)
    * `{:diet, :celiac}` forbids gluten
    * `{:allergy, tag}` forbids exactly that allergen tag

  Disliked ingredients are Preferences, not Restrictions, and have no mapping.
  """

  @diet_tags [:contains_meat, :contains_fish, :animal_product, :contains_gluten]

  @allergen_tags [
    :milk,
    :egg,
    :peanut,
    :tree_nut,
    :soy,
    :crustacean,
    :mollusc,
    :sesame,
    :mustard,
    :celery,
    :lupin,
    :sulphite
  ]

  @known_tags @diet_tags ++ @allergen_tags

  @diet_forbidden %{
    omnivore: [],
    vegetarian: [:contains_meat, :contains_fish],
    pescatarian: [:contains_meat],
    vegan: [:animal_product, :contains_meat, :contains_fish],
    celiac: [:contains_gluten]
  }

  @type tag :: atom()
  @type diet :: :omnivore | :vegetarian | :pescatarian | :vegan | :celiac
  @type restriction :: {:diet, diet()} | {:allergy, tag()}

  @doc "Every Ingredient Tag the catalog accepts."
  @spec known_tags() :: [tag()]
  def known_tags, do: @known_tags

  @doc "Ingredient Tags that can be the subject of an allergy Restriction."
  @spec allergen_tags() :: [tag()]
  def allergen_tags, do: @allergen_tags ++ [:contains_fish, :contains_gluten]

  @doc "Diets with a fixed forbidden-tag set."
  @spec diets() :: [diet()]
  def diets, do: Map.keys(@diet_forbidden)

  @doc """
  Casts an atom or string to a known tag without creating atoms from input.
  """
  @spec cast_tag(atom() | String.t()) :: {:ok, tag()} | {:error, :unknown_tag}
  def cast_tag(tag) when is_atom(tag) do
    if tag in @known_tags, do: {:ok, tag}, else: {:error, :unknown_tag}
  end

  def cast_tag(tag) when is_binary(tag) do
    case Enum.find(@known_tags, &(Atom.to_string(&1) == tag)) do
      nil -> {:error, :unknown_tag}
      known -> {:ok, known}
    end
  end

  def cast_tag(_), do: {:error, :unknown_tag}

  @doc "Returns the forbidden Ingredient Tags of a Restriction."
  @spec forbidden_tags(restriction()) :: MapSet.t(tag())
  def forbidden_tags({:diet, diet}) do
    case Map.fetch(@diet_forbidden, diet) do
      {:ok, tags} -> MapSet.new(tags)
      :error -> raise ArgumentError, "unknown diet: #{inspect(diet)}"
    end
  end

  def forbidden_tags({:allergy, tag} = restriction) do
    if tag in allergen_tags() do
      MapSet.new([tag])
    else
      raise ArgumentError, "unknown allergy restriction: #{inspect(restriction)}"
    end
  end

  def forbidden_tags(other), do: raise(ArgumentError, "unknown restriction: #{inspect(other)}")
end
