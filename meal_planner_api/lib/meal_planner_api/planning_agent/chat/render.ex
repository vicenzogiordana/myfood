defmodule MealPlannerApi.PlanningAgent.Chat.Render do
  @moduledoc """
  Text rendering of the planning chat. Everything here is read from the
  session's events and code-built Proposals (statuses, totals, budget
  checks, Deviations), never from the model's own words, so the status line
  reports what the code decided.
  """

  @doc "Lines for one session event, or `[]` when it shows nothing."
  @spec event(map()) :: [String.t()]
  def event(%{"type" => "assistant_message", "text" => text}), do: ["agent> " <> text]
  def event(%{"type" => "question", "text" => text}), do: ["agent? " <> text]
  def event(%{"type" => "proposal"} = proposal), do: proposal(proposal)

  def event(%{"type" => "progress", "step" => "tool_finished"} = event),
    do: ["  . #{event["tool"]} (#{event["outcome"]})"]

  def event(%{"type" => "progress"}), do: []

  def event(%{"type" => "limit_reached", "limit" => limit}),
    do: ["[limit] #{limit} reached: /continue authorizes one more stretch, or send a new message"]

  def event(%{"type" => "agent_unavailable", "reason" => reason}),
    do: ["[unavailable] the agent stopped: #{reason}"]

  def event(%{"type" => "session_budget_exhausted"} = event) do
    latest =
      case event["proposal"] do
        %{} = proposal -> ["latest proposal:" | proposal(proposal)]
        _ -> ["no proposal was presented"]
      end

    ["[exhausted] #{event["limit"]}: #{event["message"]}" | latest]
  end

  def event(%{"type" => "optimizer_failed", "reason" => reason}),
    do: ["[optimizer] failed: #{reason}"]

  def event(%{"type" => "session_brand_changed"} = event),
    do: [
      "[brand] #{event["ingredient"]}: #{event["previous_brand"] || "none"} -> " <>
        "#{event["brand"] || "none"} (#{event["source"]})"
    ]

  def event(%{"type" => "recipe_draft"} = event),
    do: ["[draft recipe] #{event["name"]} (#{event["origin"]})"]

  def event(%{"type" => "proposal_invalidated"} = event),
    do: ["[invalidated] proposal #{short(event["proposal_id"])}: #{event["reason"]}"]

  def event(%{"type" => "deviations_approved"} = event),
    do: ["[approved] deviations of proposal #{short(event["proposal_id"])}"]

  def event(%{"type" => "stopped"}), do: ["[stopped] the agent halted; the session survives"]
  def event(%{"type" => "session_ended"}), do: ["[session] ended"]
  def event(%{"type" => "session_cancelled"}), do: ["[session] cancelled"]
  def event(_event), do: []

  @doc "A compact Proposal: meals by day, purchase, budget and Deviations."
  @spec proposal(map()) :: [String.t()]
  def proposal(proposal) do
    meals =
      proposal["meals"]
      |> List.wrap()
      |> Enum.group_by(& &1["date"])
      |> Enum.sort()
      |> Enum.map(fn {date, meals} ->
        "  #{date} " <>
          Enum.map_join(Enum.sort_by(meals, &slot_order(&1["slot"])), " | ", fn meal ->
            "#{meal["slot"]}: #{meal["name"]}#{if meal["draft"], do: " (draft)", else: ""}"
          end)
      end)

    purchase = proposal["purchase"] || %{}
    budget = proposal["budget"] || %{}

    lines =
      purchase
      |> Map.get("lines", [])
      |> Enum.map(fn line ->
        "    #{line["packages"]} x #{line["product"]}#{brand(line["brand"])} = " <>
          money(line["total_cents"])
      end)

    ["--- proposal #{short(proposal["proposal_id"])} (#{proposal["status"]}) ---"] ++
      meals ++
      ["  purchase: #{money(purchase["total_cents"])}#{gaps(purchase)}"] ++
      lines ++
      ["  budget: #{money(budget["budget_cents"])}, #{budget_check(budget)}"] ++
      Enum.map(List.wrap(proposal["deviations"]), &("  deviation: " <> deviation(&1))) ++
      ["---"]
  end

  @doc """
  The code-owned status line: the shown Proposal's status and budget check,
  the last run's outcome and the session's spend so far.
  """
  @spec status_line(map() | nil, String.t() | nil, non_neg_integer()) :: String.t()
  def status_line(proposal, outcome, spend_micros) do
    shown =
      case proposal do
        nil ->
          "proposal: none"

        proposal ->
          "proposal #{short(proposal["proposal_id"])}: #{proposal["status"]}, " <>
            budget_check(proposal["budget"] || %{})
      end

    "[status] #{shown} | run: #{outcome || "-"} | spend: #{usd(spend_micros)}"
  end

  @doc "Micro-USD as dollars."
  @spec usd(non_neg_integer()) :: String.t()
  def usd(micros), do: "US$" <> :erlang.float_to_binary(micros / 1_000_000, decimals: 4)

  @doc "Cents as an amount of the catalog's currency (ARS)."
  @spec money(integer() | nil) :: String.t()
  def money(nil), do: "-"

  def money(cents) when is_integer(cents),
    do: "ARS " <> :erlang.float_to_binary(cents / 100, decimals: 2)

  defp budget_check(%{"budget_cents" => nil}), do: "no budget set"
  defp budget_check(%{"within_budget" => true}), do: "within budget"
  defp budget_check(%{"within_budget" => false}), do: "over budget"
  defp budget_check(%{"within_budget" => nil}), do: "budget fit unknown (prices missing)"
  defp budget_check(_budget), do: "-"

  defp gaps(purchase) do
    missing = length(purchase["missing_prices"] || [])
    stale = length(purchase["stale_prices"] || [])

    [if(missing > 0, do: "#{missing} missing prices"), if(stale > 0, do: "#{stale} stale prices")]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> ""
      notes -> " (" <> Enum.join(notes, ", ") <> ")"
    end
  end

  defp deviation(%{"type" => "budget"} = deviation),
    do: "budget exceeded by #{money(deviation["difference_cents"])}"

  defp deviation(deviation), do: inspect(deviation)

  defp brand(nil), do: ""
  defp brand(brand), do: " [#{brand}]"

  defp slot_order(slot), do: Enum.find_index(~w(breakfast lunch snack dinner), &(&1 == slot))

  defp short(nil), do: "-"
  defp short(id), do: String.slice(id, 0, 8)
end
