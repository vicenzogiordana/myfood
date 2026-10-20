defmodule MealPlannerApi.PlanningAgent.IngredientMatch do
  @moduledoc """
  Resolves Ingredient names the agent or a Member writes against the catalog
  (issue #160). Real users and real catalogs spell the same Ingredient
  differently ("mozzarella" / "Muzzarella", "limon" / "Limón", "huevo" /
  "Huevos"), so matching is by similarity, not by literal text.

  Similarity is `pg_trgm` trigram similarity over `ingredient_search_key/1`
  (`unaccent` of the lowercased name, see the migration that adds it), served
  by a GIN trigram index. The score of a catalog name for a request is the
  greater of their whole-name similarity and the word similarity of the
  request inside the catalog name, so "harina" scores "Harina de trigo" as
  high as the word it shares. Candidates scoring below #{0.4} are left out.

    * `close_matches/1` — catalog names close to each request, best first;
      an empty list means nothing in the catalog is close
    * `resolve/1` — the catalog Ingredient each request names: its exact
      name (case-insensitive) or, when exactly one close candidate is the
      same name up to case, accents, punctuation and a plural ending, that
      one. A merely similar name ("queso crema" / "Queso cremoso") is never
      resolved: it stays a close match for the agent and the household to
      choose
  """

  import Ecto.Query

  alias MealPlannerApi.Persistence.Catalog.Ingredient
  alias MealPlannerApi.Repo

  @threshold 0.4
  @max_matches 5
  @accented "áàâäéèêëíìîïóòôöúùûüñç"
  @plain "aaaaeeeeiiiioooouuuunc"
  @plain_by_accented @accented
                     |> String.to_charlist()
                     |> Enum.zip(String.to_charlist(@plain))
                     |> Map.new()

  @candidates_sql """
  SELECT q.name, m.id, m.name
  FROM unnest($1::text[]) AS q(name)
  CROSS JOIN LATERAL (
    SELECT i.id, i.name,
           greatest(
             similarity(ingredient_search_key(i.name), ingredient_search_key(q.name)),
             word_similarity(ingredient_search_key(q.name), ingredient_search_key(i.name))
           ) AS score
    FROM ingredients AS i
    WHERE ingredient_search_key(i.name) % ingredient_search_key(q.name)
       OR ingredient_search_key(q.name) <% ingredient_search_key(i.name)
    ORDER BY score DESC, i.name
    LIMIT $2
  ) AS m
  """

  @doc "The lowest similarity score a close match has."
  @spec threshold() :: float()
  def threshold, do: @threshold

  @doc """
  Catalog names close to each of `names`, best first (at most
  #{@max_matches}), by requested name.
  """
  @spec close_matches([String.t()]) :: %{String.t() => [String.t()]}
  def close_matches(names) do
    names
    |> candidates()
    |> Map.new(fn {name, found} -> {name, Enum.map(found, & &1.name)} end)
  end

  @doc """
  The catalog Ingredient each of `names` resolves to, by requested name.
  Names that resolve to nothing are left out.
  """
  @spec resolve([String.t()]) :: %{String.t() => Ingredient.t()}
  def resolve(names) do
    names = names |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) |> Enum.uniq()
    exact = exact(names)
    unresolved = Enum.reject(names, &Map.has_key?(exact, String.downcase(&1)))

    variant_ids =
      unresolved
      |> candidates()
      |> Enum.flat_map(fn {name, found} ->
        case Enum.filter(found, &same_name?(name, &1.name)) do
          [only] -> [{name, only.id}]
          _none_or_ambiguous -> []
        end
      end)

    by_id =
      case Enum.map(variant_ids, &elem(&1, 1)) do
        [] -> %{}
        ids -> from(i in Ingredient, where: i.id in ^ids) |> Repo.all() |> Map.new(&{&1.id, &1})
      end

    names
    |> Enum.flat_map(fn name ->
      case Map.fetch(exact, String.downcase(name)) do
        {:ok, ingredient} -> [{name, ingredient}]
        :error -> []
      end
    end)
    |> Kernel.++(Enum.map(variant_ids, fn {name, id} -> {name, Map.fetch!(by_id, id)} end))
    |> Map.new()
  end

  # ---------------------------------------------------------------------------

  defp exact([]), do: %{}

  defp exact(names) do
    lowered = Enum.map(names, &String.downcase/1)

    from(i in Ingredient, where: fragment("lower(?)", i.name) in ^lowered)
    |> Repo.all()
    |> Map.new(&{String.downcase(&1.name), &1})
  end

  # Close candidates by requested name, best first. The trigram operators use
  # the index; their thresholds are set for this query's transaction only.
  defp candidates(names) do
    wanted = names |> Enum.reject(&(String.trim(&1) == "")) |> Enum.uniq()
    empty = Map.new(names, &{&1, []})

    case wanted do
      [] ->
        empty

      wanted ->
        {:ok, rows} =
          Repo.transaction(fn ->
            Repo.query!("SELECT set_config('pg_trgm.similarity_threshold', $1, true)", [
              to_string(@threshold)
            ])

            Repo.query!("SELECT set_config('pg_trgm.word_similarity_threshold', $1, true)", [
              to_string(@threshold)
            ])

            Repo.query!(@candidates_sql, [wanted, @max_matches]).rows
          end)

        Enum.reduce(Enum.reverse(rows), empty, fn [name, id, catalog_name], acc ->
          {:ok, id} = Ecto.UUID.load(id)
          Map.update(acc, name, [], &[%{id: id, name: catalog_name} | &1])
        end)
    end
  end

  # The same name up to case, accents, punctuation and a plural ending of
  # each word: "limon" / "Limón", "huevo" / "Huevos", "tomates" / "Tomate".
  defp same_name?(a, b) do
    a = words(a)
    b = words(b)
    length(a) == length(b) and Enum.all?(Enum.zip(a, b), fn {x, y} -> same_word?(x, y) end)
  end

  defp same_word?(a, b), do: a == b or plural?(a, b) or plural?(b, a)

  defp plural?(singular, plural), do: plural in [singular <> "s", singular <> "es"]

  defp words(name) do
    name
    |> String.downcase()
    |> String.to_charlist()
    |> Enum.map(&Map.get(@plain_by_accented, &1, &1))
    |> List.to_string()
    |> String.split(~r/[^a-z0-9]+/, trim: true)
  end
end
