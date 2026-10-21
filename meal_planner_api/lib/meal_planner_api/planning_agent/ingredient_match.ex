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
    * `similar_ids/1` — the Ingredients close to one name, for searches
    * `resolve/1` — the catalog Ingredient each request names: its exact
      name (case-insensitive) or, when exactly one close candidate is the
      same name up to case, accents, punctuation and a plural ending, that
      one. A merely similar name ("queso crema" / "Queso cremoso") is never
      resolved here; `lookup_prices` and `set_session_brand` stop at this
      step and list it with its close matches
    * `clear_matches/1` — for `create_recipe` only, on the names `resolve/1`
      left out (issue #164): the one close candidate of each request, when
      it is the only one or its lead over the next, rounded to #{4}
      decimals (issue #166), is at least #{0.2}. So "Queso mozzarella" is
      used as "Muzzarella", its only candidate, and a merely similar name
      with no rival is used too. A request whose top candidates score
      alike ("harina 000" / "Harina de trigo", "Harina leudante") is left
      out, for the agent to choose from `close_matches/1`
  """

  import Ecto.Query

  alias MealPlannerApi.Persistence.Catalog.Ingredient
  alias MealPlannerApi.Repo

  @threshold 0.4
  @clear_lead 0.2
  @lead_precision 4
  @max_matches 5
  @max_search_matches 20
  @accented "áàâäéèêëíìîïóòôöúùûüñç"
  @plain "aaaaeeeeiiiioooouuuunc"
  @plain_by_accented @accented
                     |> String.to_charlist()
                     |> Enum.zip(String.to_charlist(@plain))
                     |> Map.new()

  @candidates_sql """
  SELECT q.name, m.id, m.name, m.score::float
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
    |> candidates(@max_matches)
    |> Map.new(fn {name, found} -> {name, Enum.map(found, & &1.name)} end)
  end

  @doc """
  Ids of the catalog Ingredients close to `name` (at most
  #{@max_search_matches}), for searches that filter by Ingredient.
  """
  @spec similar_ids(String.t()) :: [Ecto.UUID.t()]
  def similar_ids(name) do
    [name] |> candidates(@max_search_matches) |> Map.get(name, []) |> Enum.map(& &1.id)
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
      |> candidates(@max_matches)
      |> Enum.flat_map(fn {name, found} ->
        case Enum.filter(found, &same_name?(name, &1.name)) do
          [only] -> [{name, only.id}]
          _none_or_ambiguous -> []
        end
      end)

    by_id = by_id(Enum.map(variant_ids, &elem(&1, 1)))

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

  @doc """
  The catalog Ingredient each of `names` clearly means, by requested name:
  its only close candidate, or a top candidate scoring at least
  #{@clear_lead} above the next one. Ambiguous names and names without
  candidates are left out.
  """
  @spec clear_matches([String.t()]) :: %{String.t() => Ingredient.t()}
  def clear_matches(names) do
    clear_ids =
      names
      |> candidates(@max_matches)
      |> Enum.flat_map(fn {name, found} ->
        case found do
          [only] -> [{name, only.id}]
          [top, next | _] -> if clear_lead?(top, next), do: [{name, top.id}], else: []
          [] -> []
        end
      end)

    by_id = by_id(Enum.map(clear_ids, &elem(&1, 1)))
    Map.new(clear_ids, fn {name, id} -> {name, Map.fetch!(by_id, id)} end)
  end

  # ---------------------------------------------------------------------------

  # Scores are float4 similarities read as floats, so a lead of exactly
  # 0.2 (1.0 against 0.8) subtracts to 0.19999998. The lead is
  # rounded first so that noise never flips the decision (issue #166).
  defp clear_lead?(top, next),
    do: Float.round(top.score - next.score, @lead_precision) >= @clear_lead

  defp by_id([]), do: %{}

  defp by_id(ids),
    do: from(i in Ingredient, where: i.id in ^ids) |> Repo.all() |> Map.new(&{&1.id, &1})

  defp exact([]), do: %{}

  defp exact(names) do
    lowered = Enum.map(names, &String.downcase/1)

    from(i in Ingredient, where: fragment("lower(?)", i.name) in ^lowered)
    |> Repo.all()
    |> Map.new(&{String.downcase(&1.name), &1})
  end

  # Close candidates by requested name, best first. The trigram operators use
  # the index; their thresholds are set for this query's transaction only.
  defp candidates(names, limit) do
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

            Repo.query!(@candidates_sql, [wanted, limit]).rows
          end)

        Enum.reduce(Enum.reverse(rows), empty, fn [name, id, catalog_name, score], acc ->
          {:ok, id} = Ecto.UUID.load(id)
          Map.update(acc, name, [], &[%{id: id, name: catalog_name, score: score} | &1])
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
