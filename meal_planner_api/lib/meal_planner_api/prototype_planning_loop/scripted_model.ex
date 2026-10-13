# Throwaway prototype for issue #88 (bounded planning loop). Not production code.
defmodule MealPlannerApi.PrototypePlanningLoop.ScriptedModel do
  @moduledoc """
  Replays a fixed sequence of tool calls for the two prototype cases, so the
  loop, tools, real optimizer and validator run with no network and no spend.
  State is the list of remaining steps; each step builds its output items from
  the input it receives.
  """

  @behaviour MealPlannerApi.PrototypePlanningLoop.Model

  @zero_usage %{input_tokens: 0, cached_input_tokens: 0, output_tokens: 0}

  @doc "Initial state for a case."
  def new("simple") do
    [
      call("search_recipes", %{slot: nil, query: nil}),
      call("lookup_prices", %{ingredient_ids: ["rice", "eggs", "chicken"]}),
      call("run_optimizer", %{pinned: [], exclude_recipe_ids: []}),
      &present_last_solution/1,
      text("Plan semanal listo y validado: cubre los 7 días dentro del presupuesto.")
    ]
  end

  def new("allergen") do
    [
      call("search_recipes", %{slot: "dinner", query: "pad thai"}),
      call("run_optimizer", %{
        pinned: [%{day: "wed", slot: "dinner", recipe_id: "d_pad_thai"}],
        exclude_recipe_ids: []
      }),
      call("ask_human", %{
        question:
          "El pad thai de maní contiene maní y Bruno es alérgico al maní, así que no puedo incluirlo. ¿Lo reemplazo por otra cena segura o preferís otra opción?"
      }),
      call("run_optimizer", %{pinned: [], exclude_recipe_ids: ["d_pad_thai"]}),
      &present_last_solution/1,
      text("Plan semanal listo y validado, sin el pad thai de maní.")
    ]
  end

  @doc "Human lines that drive each case, in order."
  def human_lines("simple"), do: ["Planificá la semana para mi hogar."]

  def human_lines("allergen") do
    [
      "Planificá la semana y fijá el pad thai de maní para la cena del miércoles.",
      "No, reemplazalo por otra cena segura."
    ]
  end

  @impl true
  def respond([], _request) do
    {:ok,
     %{output: [message("Guion terminado: no hay más pasos.")], usage: @zero_usage, spend: nil},
     []}
  end

  def respond([step | rest], request) do
    {:ok, %{output: [step.(request.input)], usage: @zero_usage, spend: nil}, rest}
  end

  defp call(name, arguments), do: fn _input -> function_call(name, arguments) end
  defp text(text), do: fn _input -> message(text) end

  defp present_last_solution(input) do
    meals =
      input
      |> Enum.reverse()
      |> Enum.find_value([], fn
        %{"type" => "function_call_output", "output" => output} -> Jason.decode!(output)["meals"]
        _ -> nil
      end)

    function_call("present_proposal", %{meals: meals, notes: "scripted"})
  end

  defp function_call(name, arguments) do
    %{
      "type" => "function_call",
      "call_id" => "scripted_#{System.unique_integer([:positive])}",
      "name" => name,
      "arguments" => Jason.encode!(arguments)
    }
  end

  defp message(text) do
    %{
      "type" => "message",
      "role" => "assistant",
      "content" => [%{"type" => "output_text", "text" => text}]
    }
  end
end
