# Throwaway prototype for issue #88 (bounded planning loop). Not production code.
defmodule Mix.Tasks.Prototype.PlanningLoop do
  @shortdoc "Throwaway terminal chat for the issue #88 planning-loop prototype"

  @moduledoc """
  Terminal chat over the bounded planning loop. Does not start the application
  or the database.

      mix prototype.planning_loop                      # live, needs OPENAI_API_KEY
      mix prototype.planning_loop --scripted simple    # no network, no spend
      mix prototype.planning_loop --scripted allergen  # no network, no spend

  See `lib/meal_planner_api/prototype_planning_loop/README.md`.
  """

  use Mix.Task

  alias MealPlannerApi.PrototypePlanningLoop.{
    Fixtures,
    Loop,
    OpenAIModel,
    ScriptedModel,
    SpendLedger
  }

  @bold "\e[1m"
  @dim "\e[2m"
  @reset "\e[0m"

  @impl true
  def run(args) do
    # Loads config and compiles without starting the app, so no Repo is needed.
    Mix.Task.run("app.config")
    {opts, _rest} = OptionParser.parse!(args, strict: [scripted: :string])

    case opts[:scripted] do
      nil -> live()
      scripted when scripted in ["simple", "allergen"] -> scripted(scripted)
      other -> fail("Caso desconocido: #{other}. Usá --scripted simple o --scripted allergen.")
    end
  end

  # ---- live chat ----

  defp live do
    if not OpenAIModel.key_present?() do
      fail(
        "Falta OPENAI_API_KEY en el entorno. No se hizo ninguna llamada de red.\n" <>
          "Exportala en tu shell (ver README) o probá sin gasto: mix prototype.planning_loop --scripted simple"
      )
    end

    {:ok, _apps} = Application.ensure_all_started(:req)
    spend = SpendLedger.summary()

    say(
      "#{@bold}Prototipo #88: bucle de planificación#{@reset} #{@dim}(descartable, datos ficticios)#{@reset}"
    )

    say("Modelo: #{OpenAIModel.model_name()} · gasto acumulado: #{spend_text(spend)}")

    household = pick_household()
    say("Escribí tu pedido. #{@dim}/salir para terminar.#{@reset}")
    chat(Loop.new(household.id, {OpenAIModel, nil}, &print_event/1))
  end

  defp pick_household do
    say("\nHogares:")

    Fixtures.households()
    |> Enum.with_index(1)
    |> Enum.each(fn {household, index} ->
      members =
        Enum.map_join(household.members, ", ", fn member ->
          case member.allergies do
            [] -> member.name
            allergies -> "#{member.name} (alergia: #{Enum.join(allergies, ", ")})"
          end
        end)

      say(
        "  #{@bold}#{index}#{@reset}. #{household.name}: #{members} · presupuesto #{money(household.weekly_budget_cents)}"
      )
    end)

    case prompt("Elegí un hogar (número): ") do
      nil ->
        exit(:normal)

      line ->
        with {index, ""} <- Integer.parse(line),
             %{} = household <- Enum.at(Fixtures.households(), index - 1),
             true <- index > 0 do
          household
        else
          _ -> pick_household()
        end
    end
  end

  defp chat(session) do
    case prompt("\n#{@bold}vos>#{@reset} ") do
      quit when quit in [nil, "/salir"] ->
        say("Fin.")

      "" ->
        chat(session)

      line ->
        {outcome, session} = Loop.run(session, line)
        print_outcome(outcome, session)
        chat(session)
    end
  end

  defp prompt(label) do
    case IO.gets(label) do
      line when is_binary(line) -> String.trim(line)
      _eof -> nil
    end
  end

  # ---- scripted cases ----

  defp scripted(name) do
    household_id = if name == "simple", do: "aurora", else: "boreal"

    say(
      "#{@bold}Caso guionado: #{name}#{@reset} #{@dim}(modelo guionado, sin red ni gasto; hogar #{household_id})#{@reset}"
    )

    parent = self()

    on_event = fn event ->
      print_event(event)
      send(parent, {:prototype_event, event})
    end

    session = Loop.new(household_id, {ScriptedModel, ScriptedModel.new(name)}, on_event)

    {outcomes, _session} =
      Enum.map_reduce(ScriptedModel.human_lines(name), session, fn line, session ->
        say("\n#{@bold}vos>#{@reset} #{line}")
        {outcome, session} = Loop.run(session, line)
        print_outcome(outcome, session)
        {outcome, session}
      end)

    case check(name, outcomes, drain_events()) do
      :ok -> say("\n#{@bold}RESULTADO ESPERADO: OK#{@reset}")
      {:error, reason} -> fail("\nRESULTADO INESPERADO: #{reason}")
    end
  end

  defp drain_events do
    receive do
      {:prototype_event, event} -> [event | drain_events()]
    after
      0 -> []
    end
  end

  defp check("simple", outcomes, events) do
    cond do
      not match?([{:reply, _}], outcomes) -> {:error, "the turn did not end in a reply"}
      not valid_full_plan?(events) -> {:error, "no validated 7-day plan"}
      true -> :ok
    end
  end

  defp check("allergen", outcomes, events) do
    # Every plan the tools produced or the model proposed, valid or not.
    planned = Enum.flat_map(events, &plan_meals/1)

    cond do
      not match?([{:ask, _}, {:reply, _}], outcomes) ->
        {:error, "expected a question, then a reply"}

      Enum.any?(planned, &(&1["recipe_id"] == "d_pad_thai")) ->
        {:error, "the allergen recipe appeared in a plan"}

      not valid_full_plan?(events) ->
        {:error, "no validated 7-day plan after the answer"}

      true ->
        :ok
    end
  end

  defp plan_meals({:validation, verdict}), do: verdict.meals
  defp plan_meals({:tool_result, "run_optimizer", %{meals: meals}}), do: meals
  defp plan_meals(_event), do: []

  defp valid_full_plan?(events) do
    cells = length(Fixtures.days()) * length(Fixtures.slots())

    Enum.any?(
      events,
      &match?({:validation, %{valid: true, meals: meals}} when length(meals) == cells, &1)
    )
  end

  # ---- rendering ----

  # The status line comes from the validator, not from the model's text, so a
  # reply that claims a valid plan cannot pass for one.
  defp print_outcome(outcome, session) do
    case outcome do
      {:reply, text} -> say("\n#{@bold}agente>#{@reset} #{text}")
      {:ask, question} -> say("\n#{@bold}agente pregunta>#{@reset} #{question}")
      {:stopped, reason} -> say("\n#{@bold}DETENIDO:#{@reset} #{reason}")
    end

    status =
      case session.latest_verdict do
        nil -> "todavía no hay ninguna propuesta"
        %{valid: true} -> "la última propuesta es VÁLIDA"
        %{valid: false} -> "la última propuesta fue RECHAZADA; no hay plan válido vigente"
      end

    say("#{@dim}[estado según el código] #{status}#{@reset}")
  end

  defp print_event({:model_turn, n, %{text: text, tool_calls: count}}) do
    say(
      "#{@dim}[turno #{n} del modelo] #{count} llamada(s) a herramientas, #{String.length(text)} caracteres de texto#{@reset}"
    )
  end

  defp print_event({:usage, _usage, nil}),
    do: say("#{@dim}  tokens: 0 (modelo guionado, sin gasto)#{@reset}")

  defp print_event({:usage, usage, spend}) do
    say(
      "#{@dim}  tokens: entrada #{usage.input_tokens} (en caché #{usage.cached_input_tokens}), salida #{usage.output_tokens} · " <>
        "esta llamada USD #{SpendLedger.fmt(spend.call_usd)} · acumulado #{spend_text(spend)}#{@reset}"
    )
  end

  defp print_event({:tool_call, "present_proposal", arguments}) do
    say(
      "  #{@bold}herramienta#{@reset} present_proposal con #{length(List.wrap(arguments["meals"]))} comidas"
    )
  end

  defp print_event({:tool_call, name, arguments}) do
    say("  #{@bold}herramienta#{@reset} #{name} #{Jason.encode!(arguments)}")
  end

  defp print_event({:tool_result, "run_optimizer", %{status: "solution"} = result}) do
    say(
      "  #{@bold}optimizador#{@reset} solución con #{length(result.meals)} comidas, costo #{money(result.total_cost_cents)} de #{money(result.weekly_budget_cents)}"
    )
  end

  defp print_event({:tool_result, "run_optimizer", result}) do
    say(
      "  #{@bold}optimizador#{@reset} sin solución: #{Jason.encode!(Map.delete(result, :solved))}"
    )
  end

  defp print_event({:tool_result, "search_recipes", %{recipes: recipes}}) do
    say(
      "  #{@dim}resultado: #{length(recipes)} receta(s): #{Enum.map_join(recipes, ", ", & &1.id)}#{@reset}"
    )
  end

  # The verdict is printed by the validation event that follows.
  defp print_event({:tool_result, "present_proposal", _result}), do: :ok

  defp print_event({:tool_result, _name, result}) do
    say("  #{@dim}resultado: #{Jason.encode!(result)}#{@reset}")
  end

  defp print_event({:validation, %{valid: true} = verdict}) do
    say(
      "  #{@bold}validación (código, fuera del modelo): VÁLIDO#{@reset} · costo #{money(verdict.total_cost_cents)} de #{money(verdict.weekly_budget_cents)}"
    )

    print_plan(verdict.meals)
  end

  defp print_event({:validation, verdict}) do
    say(
      "  #{@bold}validación (código, fuera del modelo): RECHAZADO#{@reset} · la propuesta no se muestra como válida"
    )

    Enum.each(verdict.violations, &say("    - #{Jason.encode!(&1)}"))
  end

  defp print_plan(meals) do
    by_cell = Map.new(meals, &{{&1["day"], &1["slot"]}, &1["recipe_id"]})

    for day <- Fixtures.days() do
      row =
        Enum.map_join(Fixtures.slots(), " | ", fn slot ->
          recipe = Fixtures.recipe(Map.fetch!(by_cell, {day, slot}))
          "#{recipe.name} (#{money(recipe.cost_cents)})"
        end)

      say("    #{@bold}#{day}#{@reset}  #{row}")
    end
  end

  # Unreconciled reservations are worst-case amounts of calls that never
  # reported usage; they count as spent.
  defp spend_text(spend) do
    reserved =
      if spend.reserved_usd > 0 do
        " (incluye USD #{SpendLedger.fmt(spend.reserved_usd)} de reservas sin conciliar)"
      else
        ""
      end

    "USD #{SpendLedger.fmt(spend.total_usd)} de USD #{SpendLedger.fmt(spend.cap_usd)}#{reserved}"
  end

  defp money(cents), do: "$#{:erlang.float_to_binary(cents / 100, decimals: 2)}"

  defp say(text), do: IO.puts(text)

  defp fail(message) do
    IO.puts(:stderr, message)
    exit({:shutdown, 1})
  end
end
