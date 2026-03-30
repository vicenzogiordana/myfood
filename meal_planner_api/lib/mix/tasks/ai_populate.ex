defmodule Mix.Tasks.AiPopulate do
  use Mix.Task
  require Logger

  alias MealPlannerApi.AI
  alias MealPlannerApi.Persistence.Catalog

  @shortdoc "Puebla ingredientes por lotes via IA usando taxonomia de supermercado"

  @categories_map %{
    no_perecederos: [
      "Aceites Comunes, Aceites Especiales, Acetos, Jugos de Limon y Vinagres",
      "Aderezos: Mayonesas, Ketchup, Mostazas, Salsas Golf, Salsas Frias y Otros Condimentos",
      "Sal, Pimienta y Especias",
      "Conservas de Carne, Conservas de Frutas, Conservas de Pescado",
      "Conservas de Verduras y Legumbres (ej: arvejas, choclo, tomate)",
      "Desayuno: Azucar, Edulcorantes, Cacao, Saborizantes, Cafes, Tes y Yerbas",
      "Desayuno: Bizcochuelos, Budines, Magdalenas y Piononos empaquetados",
      "Desayuno: Cereales, Galletitas Dulces y Galletitas Saladas",
      "Desayuno: Mermeladas y Jaleas",
      "Golosinas: Alfajores, Bocaditos, Postres y Huevos de Pascua",
      "Golosinas: Bombones, Caramelos, Chicles, Chocolates, Turrones y Grageas",
      "Sopas, Caldos y Pure instantaneo",
      "Para Preparar: Bizcochuelos, Brownies, Tortas, Flanes, Gelatinas, Helados y Postres",
      "Pastas Secas Guiseras, Pastas Secas Largas y Pastas Listas",
      "Salsas listas para pastas (ej: fileto, pomarola)",
      "Snacks: Frutas Secas, Mani, Nachos, Palitos de Maiz, Palitos Salados, Papas Fritas y Pochoclos"
    ],
    granos: [
      "Arroz blanco, integral y Arroces Listos",
      "Legumbres secas (lentejas, garbanzos, porotos)",
      "Harinas (trigo, maiz, etc.), Avenas y Semolas",
      "Panificados industriales: Lacteados, Pan Para Hamburguesas y Panchos",
      "Panificados secos: Tostadas, Grisines, Pan Rallado y Rebozador",
      "Semillas y granos sueltos"
    ],
    frutas: [
      "Frutas Empaquetadas y Frutas Sueltas frescas",
      "Frutas Secas y Desecadas (pasas, ciruelas, datiles)"
    ],
    verduras: [
      "Hierbas Aromaticas frescas y Plantines",
      "Hortalizas Livianas y Frescas de Hoja",
      "Hortalizas Pesadas (papa, batata, zapallo, etc.)",
      "Verduras Empaquetadas, Procesadas y Ensaladas Listas",
      "Verduras Secas y Desecadas (tomate seco, hongos)"
    ],
    carnes: [
      "Carne Vacuna: Novillito, Novillito Especial, La Hacienda Premium",
      "Carne de Cerdo",
      "Cordero, Lechon, Chivito y Conejo",
      "Listos Para Cocinar (brochettes, arrollados de carne crudos)",
      "Embutidos: Chorizos, Morcilla, Salchichas frescas",
      "Pollos enteros, trozados y Menudencias",
      "Pescados frescos y Mariscos frescos",
      "Fiambres: Jamon Cocido y Crudo",
      "Otros fiambres (salamines, mortadela, bondiola, leberwurst) y Salchichas de viena"
    ],
    lacteos: [
      "Quesos Untables y Quesos Port Salut / Cremosos",
      "Queso Muzzarella",
      "Quesos Semiblandos, Quesos Duros, Rallados y Ricota",
      "Quesos Especiales e Importados (brie, camembert, roquefort)",
      "Cremas de leche y Dulce de Leche",
      "Leches Larga Vida, Refrigeradas y Saborizadas",
      "Bebidas Vegetales (almendra, soja, coco)",
      "Mantecas y Margarinas",
      "Yogures Descremados y Yogures Enteros"
    ],
    congelados: [
      "Comidas Congeladas: Pizzas, Empanadas y Tartas",
      "Frutas y Vegetales Congelados",
      "Hamburguesas y Milanesas Congeladas",
      "Helados y Postres Congelados",
      "Papas, Pescados, Mariscos, Pollo y Carnes Congeladas"
    ],
    otros: [
      "Huevos (blancos, colorados, codorniz)",
      "Pastas Frescas: Simples y Rellenas (fideos, ravioles, sorrentinos)",
      "Salsa frescas, Grasas (bovina, cerdo)",
      "Masas y Levaduras, Tapas de empanadas y pascualinas",
      "Panaderia Salada: Panificados frescos, Pizzas y Focaccias, Sandwiches de Miga",
      "Panaderia Dulce y Pasteleria fresca (facturas, masas, tortas)",
      "Encurtidos, Aceitunas y Pickles"
    ]
  }

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _argv, _invalid} =
      OptionParser.parse(args,
        strict: [
          dry_run: :boolean,
          sleep_ms: :integer,
          per_topic: :integer,
          max_topics: :integer,
          only_category: :string
        ]
      )

    dry_run = Keyword.get(opts, :dry_run, false)
    sleep_ms = max(Keyword.get(opts, :sleep_ms, 1500), 0)
    per_topic = clamp(Keyword.get(opts, :per_topic, 20), 5, 30)
    max_topics = Keyword.get(opts, :max_topics, :all)
    only_category = parse_category_filter(Keyword.get(opts, :only_category))

    selected_categories =
      @categories_map
      |> Enum.filter(fn {cat, _topics} -> is_nil(only_category) or cat == only_category end)

    if selected_categories == [] do
      Mix.raise("No hay categorias para procesar. Revisa --only-category")
    end

    stats =
      selected_categories
      |> Enum.reduce(
        %{topics: 0, requested: 0, upserts_ok: 0, upserts_error: 0, ai_errors: 0},
        fn {db_cat, topics}, acc ->
          Logger.info("\\n[AI Populate] Categoria: #{db_cat}")

          topics
          |> maybe_take(max_topics)
          |> Enum.reduce(acc, fn topic, local_acc ->
            Logger.info("[AI Populate] Topic: #{topic}")

            case ask_ai_for_ingredients(db_cat, topic, per_topic) do
              {:ok, raw_text} ->
                case decode_ingredients(raw_text) do
                  {:ok, items} ->
                    {ok_count, err_count} = save_to_db(items, db_cat, dry_run)

                    Process.sleep(sleep_ms)

                    %{
                      local_acc
                      | topics: local_acc.topics + 1,
                        requested: local_acc.requested + length(items),
                        upserts_ok: local_acc.upserts_ok + ok_count,
                        upserts_error: local_acc.upserts_error + err_count
                    }

                  {:error, reason} ->
                    Logger.error(
                      "[AI Populate] JSON invalido para topic='#{topic}' error=#{inspect(reason)}"
                    )

                    %{
                      local_acc
                      | topics: local_acc.topics + 1,
                        ai_errors: local_acc.ai_errors + 1
                    }
                end

              {:error, reason} ->
                Logger.error(
                  "[AI Populate] Error IA en topic='#{topic}' error=#{inspect(reason)}"
                )

                %{
                  local_acc
                  | topics: local_acc.topics + 1,
                    ai_errors: local_acc.ai_errors + 1
                }
            end
          end)
        end
      )

    Logger.info("\\n[AI Populate] Finalizado")
    Logger.info("  Topics procesados: #{stats.topics}")
    Logger.info("  Ingredientes recibidos: #{stats.requested}")
    Logger.info("  Upserts OK: #{stats.upserts_ok}")
    Logger.info("  Upserts error: #{stats.upserts_error}")
    Logger.info("  Errores IA/JSON: #{stats.ai_errors}")
    Logger.info("  Modo dry-run: #{dry_run}")
  end

  defp save_to_db(items, db_category, true) do
    Enum.each(items, fn item ->
      Logger.info("[DRY RUN] #{db_category} -> #{item["name"]}")
    end)

    {length(items), 0}
  end

  defp save_to_db(items, db_category, false) do
    Enum.reduce(items, {0, 0}, fn item, {ok_count, err_count} ->
      attrs = %{
        name: item["name"],
        category: db_category,
        calories_per_100: to_int(item["calories_per_100"]),
        protein_g_per_100: to_decimalish(item["protein_g_per_100"]),
        carbs_g_per_100: to_decimalish(item["carbs_g_per_100"]),
        fat_g_per_100: to_decimalish(item["fat_g_per_100"])
      }

      case Catalog.upsert_ingredient_by_name(attrs) do
        {:ok, _ingredient} ->
          {ok_count + 1, err_count}

        {:error, changeset} ->
          Logger.warning(
            "[AI Populate] Skip #{inspect(attrs.name)} -> #{inspect(changeset.errors)}"
          )

          {ok_count, err_count + 1}
      end
    end)
  end

  defp ask_ai_for_ingredients(category_atom, sub_topic, per_topic) do
    prompt = """
    Actua como data-entry de supermercado argentino y experto en nutricion.
    Genera exactamente #{per_topic} ingredientes para la gondola: \"#{sub_topic}\".
    Categoria principal de base de datos: \"#{category_atom}\".

    Reglas estrictas:
    1) Devuelve solo JSON valido, sin markdown ni texto extra.
    2) Formato de salida: array de objetos con claves exactas:
       name, calories_per_100, protein_g_per_100, carbs_g_per_100, fat_g_per_100.
    3) Sin repetidos dentro del array.
    4) Usa nombres especificos y realistas para mercado argentino.
    5) Macros y calorias deben ser numeros >= 0.
    """

    AI.generate_text(prompt,
      max_output_tokens: 2500,
      system_prompt:
        "Responde solamente un JSON array valido. No uses markdown, no uses comentarios, no agregues texto fuera del JSON."
    )
  end

  defp decode_ingredients(raw_text) when is_binary(raw_text) do
    json_text =
      raw_text
      |> String.trim()
      |> strip_code_fence()
      |> extract_json_array()

    with {:ok, decoded} <- Jason.decode(json_text),
         true <- is_list(decoded),
         normalized <- Enum.map(decoded, &normalize_item/1),
         true <- Enum.all?(normalized, &valid_item?/1) do
      {:ok, normalized}
    else
      false -> {:error, :invalid_items_shape}
      {:error, _} = error -> error
      _ -> {:error, :invalid_json_shape}
    end
  end

  defp strip_code_fence(text) do
    text
    |> String.replace(~r/^```(?:json)?\s*/i, "")
    |> String.replace(~r/\s*```$/, "")
  end

  defp extract_json_array(text) do
    case Regex.run(~r/\[[\s\S]*\]/, text) do
      [json] -> json
      _ -> text
    end
  end

  defp normalize_item(item) when is_map(item) do
    %{
      "name" => item |> Map.get("name") |> sanitize_name(),
      "calories_per_100" => to_int(Map.get(item, "calories_per_100")),
      "protein_g_per_100" => to_decimalish(Map.get(item, "protein_g_per_100")),
      "carbs_g_per_100" => to_decimalish(Map.get(item, "carbs_g_per_100")),
      "fat_g_per_100" => to_decimalish(Map.get(item, "fat_g_per_100"))
    }
  end

  defp normalize_item(_), do: %{}

  defp valid_item?(%{
         "name" => name,
         "calories_per_100" => cals,
         "protein_g_per_100" => protein,
         "carbs_g_per_100" => carbs,
         "fat_g_per_100" => fat
       }) do
    is_binary(name) and name != "" and is_integer(cals) and cals >= 0 and
      is_number(protein) and protein >= 0 and
      is_number(carbs) and carbs >= 0 and
      is_number(fat) and fat >= 0
  end

  defp valid_item?(_), do: false

  defp sanitize_name(value) when is_binary(value),
    do: value |> String.trim() |> String.slice(0, 120)

  defp sanitize_name(_), do: ""

  defp to_int(value) when is_integer(value), do: max(value, 0)
  defp to_int(value) when is_float(value), do: value |> round() |> max(0)

  defp to_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> max(int, 0)
      _ -> 0
    end
  end

  defp to_int(_), do: 0

  defp to_decimalish(value) when is_integer(value), do: value * 1.0
  defp to_decimalish(value) when is_float(value), do: if(value < 0, do: 0.0, else: value)

  defp to_decimalish(value) when is_binary(value) do
    case Float.parse(value) do
      {float, _} when float >= 0 -> float
      _ -> 0.0
    end
  end

  defp to_decimalish(_), do: 0.0

  defp parse_category_filter(nil), do: nil

  defp parse_category_filter(value) when is_binary(value) do
    atom = String.to_existing_atom(value)

    if Map.has_key?(@categories_map, atom), do: atom, else: nil
  rescue
    ArgumentError -> nil
  end

  defp maybe_take(items, :all), do: items

  defp maybe_take(items, max_topics) when is_integer(max_topics) and max_topics > 0,
    do: Enum.take(items, max_topics)

  defp maybe_take(items, _), do: items

  defp clamp(n, min, _max) when n < min, do: min
  defp clamp(n, _min, max) when n > max, do: max
  defp clamp(n, _min, _max), do: n
end
