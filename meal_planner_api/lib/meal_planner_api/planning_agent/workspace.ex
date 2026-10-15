defmodule MealPlannerApi.PlanningAgent.Workspace do
  @moduledoc """
  The Workspace of a Planning Session (spec #93, issue #99): the working state
  the agent steers through deterministic tools, never stored beyond the
  session.

    * `draft` — the latest optimizer plan, not yet validated
    * `proposal` / `proposed` — the last valid Proposal shown to the Member
      and its meals
    * `pins` — `{date, slot} => %{recipe_id, name}`: Pins beat the variety
      cap but never a Restriction
    * `excluded` — Excluded Recipes, never offered again in this session
    * `released` — `{date, slot}` meals of the last Proposal that the next
      `run_optimizer` may change; every other meal stays fixed
    * `variety_cap` — the session's variety cap

  `edit/3` applies one edit or refuses it with a reason; approvals are human
  actions and can never be set here.
  """

  alias MealPlannerApi.Optimization.Variety
  alias MealPlannerApi.PlanningAgent.RecipeSearch

  # Highest meaningful cap: every meal of a 7-day window with all four slots.
  @max_variety_cap 28
  @replacement_limit 3
  @approval_actions ~w(approve approve_deviations approve_deviation approve_absence_exception
                       approve_overspend deviation_approval absence_exception confirm confirm_plan
                       save_recipe)

  defstruct draft: nil,
            proposal: nil,
            proposed: [],
            pins: %{},
            excluded: MapSet.new(),
            released: MapSet.new(),
            variety_cap: 2

  @type key :: {Date.t(), String.t()}
  @type t :: %__MODULE__{
          draft: [map()] | nil,
          proposal: map() | nil,
          proposed: [map()],
          pins: %{key() => %{recipe_id: Ecto.UUID.t(), name: String.t()}},
          excluded: MapSet.t(Ecto.UUID.t()),
          released: MapSet.t(key()),
          variety_cap: pos_integer()
        }

  @type ctx :: %{
          required(:range) => {Date.t(), Date.t()},
          required(:slots) => [String.t()],
          required(:household) => map(),
          optional(atom()) => term()
        }

  @doc "An empty Workspace with the default variety cap."
  @spec new() :: t()
  def new, do: %__MODULE__{variety_cap: Variety.default_cap()}

  @doc """
  Applies one `edit_workspace` call. Returns `{:ok, workspace, result}` or
  `{:error, reason, extra}` where `reason` is a stable code; the Workspace is
  unchanged on error.
  """
  @spec edit(t(), map(), ctx()) :: {:ok, t(), map()} | {:error, String.t(), map()}
  def edit(%__MODULE__{} = ws, args, ctx) do
    action = Map.get(args, "action")

    cond do
      approval?(action, args) -> {:error, "approval_not_allowed", %{}}
      action == "pin" -> pin(ws, args, ctx)
      action == "unpin" -> unpin(ws, args, ctx)
      action == "exclude" -> exclude(ws, args)
      action == "include" -> include(ws, args)
      action == "release" -> release(ws, args, ctx)
      action == "release_all" -> release_all(ws)
      action == "set_variety_cap" -> set_variety_cap(ws, args)
      true -> {:error, "unknown_action", %{}}
    end
  end

  @doc "The human-facing reason of an edit refusal code."
  @spec reason(String.t()) :: String.t()
  def reason("approval_not_allowed"),
    do: "Approvals and confirmations are made only by the household in the app."

  def reason("unknown_action"),
    do: "Use pin, unpin, exclude, include, release, release_all or set_variety_cap."

  def reason("invalid_date"), do: "The date must be an ISO date (YYYY-MM-DD)."
  def reason("date_outside_range"), do: "The date is outside the Planning Range."
  def reason("unknown_slot"), do: "The slot is not planned in this session."
  def reason("invalid_recipe_id"), do: "The recipe id is not valid."
  def reason("recipe_not_found"), do: "No recipe with this id is available to the household."
  def reason("recipe_not_for_slot"), do: "This recipe does not suit that meal slot."

  def reason("restriction_conflict"),
    do:
      "This recipe conflicts with a household Restriction and cannot be pinned. " <>
        "Offer one of the safe replacements instead."

  def reason("recipe_excluded"), do: "The recipe is excluded in this session; include it first."
  def reason("recipe_pinned"), do: "The recipe is pinned; unpin it first."
  def reason("no_meal_to_keep"), do: "There is no proposed meal there to keep; name a recipe."
  def reason("not_pinned"), do: "No Pin exists for that day and slot."
  def reason("no_proposal"), do: "There is no Proposal yet; run the optimizer and present one."
  def reason("no_proposed_meal"), do: "The last Proposal has no meal for that day and slot."
  def reason("meal_pinned"), do: "That meal is pinned; unpin it before releasing it."
  def reason("search_failed"), do: "The recipe lookup failed; try again."

  def reason("invalid_variety_cap"),
    do: "The variety cap must be an integer from 1 to #{@max_variety_cap}."

  @doc """
  The meals the optimizer must keep: every Pin plus, once a Proposal exists,
  each of its meals that was not released.
  """
  @spec fixed_meals(t()) :: [%{date: Date.t(), slot: String.t(), recipe_id: Ecto.UUID.t()}]
  def fixed_meals(%__MODULE__{} = ws) do
    kept =
      for meal <- ws.proposed,
          key = {meal.date, meal.slot},
          not MapSet.member?(ws.released, key),
          not Map.has_key?(ws.pins, key),
          into: %{},
          do: {key, meal.recipe_id}

    pins = Map.new(ws.pins, fn {key, pin} -> {key, pin.recipe_id} end)

    kept
    |> Map.merge(pins)
    |> Enum.map(fn {{date, slot}, recipe_id} ->
      %{date: date, slot: slot, recipe_id: recipe_id}
    end)
    |> Enum.sort_by(&{Date.to_iso8601(&1.date), &1.slot})
  end

  @doc """
  Records a valid Proposal: its meals become the base of the next
  re-optimization and no meal is released any more.
  """
  @spec present(t(), map(), [map()]) :: t()
  def present(%__MODULE__{} = ws, proposal, meals) do
    proposed = Enum.map(meals, &Map.take(&1, [:date, :slot, :recipe_id, :name]))
    %{ws | proposal: proposal, proposed: proposed, released: MapSet.new()}
  end

  @doc "The Workspace as `get_workspace` returns it to the agent."
  @spec to_data(t(), ctx()) :: map()
  def to_data(%__MODULE__{} = ws, ctx) do
    order = slot_order(ctx)

    %{
      "proposal" =>
        ws.proposal &&
          %{"proposal_id" => ws.proposal["proposal_id"], "meals" => ws.proposal["meals"]},
      "draft" => ws.draft && Enum.map(ws.draft, &meal_key_data/1),
      "pins" =>
        ws.pins
        |> Enum.sort_by(fn {key, _pin} -> sort_key(key, order) end)
        |> Enum.map(fn {{date, slot}, pin} ->
          %{
            "date" => Date.to_iso8601(date),
            "slot" => slot,
            "recipe_id" => pin.recipe_id,
            "name" => pin.name
          }
        end),
      "excluded_recipe_ids" => ws.excluded |> MapSet.to_list() |> Enum.sort(),
      "released" =>
        ws.released
        |> Enum.sort_by(&sort_key(&1, order))
        |> Enum.map(fn {date, slot} -> %{"date" => Date.to_iso8601(date), "slot" => slot} end),
      "variety_cap" => ws.variety_cap
    }
  end

  # ---------------------------------------------------------------------------
  # Edits
  # ---------------------------------------------------------------------------

  defp pin(ws, args, ctx) do
    with {:ok, key} <- meal_key(args, ctx),
         {:ok, recipe_id} <- pin_recipe_id(ws, args, key),
         :ok <- not_excluded(ws, recipe_id),
         {:ok, recipe} <- pinnable_recipe(ctx, ws, recipe_id, key) do
      ws = %{
        ws
        | pins: Map.put(ws.pins, key, %{recipe_id: recipe.id, name: recipe.name}),
          released: MapSet.delete(ws.released, key)
      }

      {:ok, ws, %{"status" => "ok", "pinned" => pin_data(key, recipe)}}
    end
  end

  defp unpin(ws, args, ctx) do
    with {:ok, key} <- meal_key(args, ctx) do
      if Map.has_key?(ws.pins, key),
        do: {:ok, %{ws | pins: Map.delete(ws.pins, key)}, %{"status" => "ok"}},
        else: {:error, "not_pinned", %{}}
    end
  end

  defp exclude(ws, args) do
    with {:ok, recipe_id} <- recipe_id_arg(args) do
      if Enum.any?(ws.pins, fn {_key, pin} -> pin.recipe_id == recipe_id end) do
        {:error, "recipe_pinned", %{}}
      else
        # A proposed meal of an Excluded Recipe cannot stay: it is released.
        released =
          for meal <- ws.proposed, meal.recipe_id == recipe_id, do: {meal.date, meal.slot}

        ws = %{
          ws
          | excluded: MapSet.put(ws.excluded, recipe_id),
            released: MapSet.union(ws.released, MapSet.new(released))
        }

        {:ok, ws, %{"status" => "ok", "released" => Enum.map(released, &key_data/1)}}
      end
    end
  end

  defp include(ws, args) do
    with {:ok, recipe_id} <- recipe_id_arg(args) do
      {:ok, %{ws | excluded: MapSet.delete(ws.excluded, recipe_id)}, %{"status" => "ok"}}
    end
  end

  defp release(%{proposal: nil}, _args, _ctx), do: {:error, "no_proposal", %{}}

  defp release(ws, args, ctx) do
    with {:ok, key} <- meal_key(args, ctx) do
      cond do
        Map.has_key?(ws.pins, key) ->
          {:error, "meal_pinned", %{}}

        not Enum.any?(ws.proposed, &({&1.date, &1.slot} == key)) ->
          {:error, "no_proposed_meal", %{}}

        true ->
          {:ok, %{ws | released: MapSet.put(ws.released, key)}, %{"status" => "ok"}}
      end
    end
  end

  # "Redo the whole week": every meal of the Proposal is released. Pins last
  # for the whole Planning Session, so they stay (and are reported) until the
  # Member asks to unpin them.
  defp release_all(%{proposal: nil}), do: {:error, "no_proposal", %{}}

  defp release_all(ws) do
    released =
      for meal <- ws.proposed,
          key = {meal.date, meal.slot},
          not Map.has_key?(ws.pins, key),
          into: MapSet.new(),
          do: key

    pinned =
      ws.pins
      |> Map.keys()
      |> Enum.sort_by(&Date.to_iso8601(elem(&1, 0)))
      |> Enum.map(&key_data/1)

    {:ok, %{ws | released: released},
     %{"status" => "ok", "released_count" => MapSet.size(released), "still_pinned" => pinned}}
  end

  defp set_variety_cap(ws, %{"variety_cap" => cap})
       when is_integer(cap) and cap >= 1 and cap <= @max_variety_cap,
       do: {:ok, %{ws | variety_cap: cap}, %{"status" => "ok", "variety_cap" => cap}}

  defp set_variety_cap(_ws, _args), do: {:error, "invalid_variety_cap", %{}}

  # ---------------------------------------------------------------------------
  # Validation helpers
  # ---------------------------------------------------------------------------

  defp approval?(action, args) do
    action in @approval_actions or
      Enum.any?(Map.keys(args), &(is_binary(&1) and String.contains?(&1, "approv")))
  end

  defp meal_key(args, ctx) do
    {from_date, to_date} = ctx.range

    slot = Map.get(args, "slot")

    case date_arg(args) do
      {:error, reason} ->
        {:error, reason, %{}}

      {:ok, date} ->
        cond do
          Date.compare(date, from_date) == :lt or Date.compare(date, to_date) == :gt ->
            {:error, "date_outside_range", %{}}

          slot not in ctx.slots ->
            {:error, "unknown_slot", %{}}

          true ->
            {:ok, {date, slot}}
        end
    end
  end

  defp date_arg(args) do
    with value when is_binary(value) <- Map.get(args, "date"),
         {:ok, date} <- Date.from_iso8601(value) do
      {:ok, date}
    else
      _ -> {:error, "invalid_date"}
    end
  end

  defp recipe_id_arg(args) do
    case args |> Map.get("recipe_id") |> cast_uuid() do
      {:ok, id} -> {:ok, id}
      :error -> {:error, "invalid_recipe_id", %{}}
    end
  end

  # Without a recipe the Pin keeps the proposed meal ("keep Monday's dinner").
  defp pin_recipe_id(ws, args, key) do
    case Map.fetch(args, "recipe_id") do
      {:ok, _} ->
        recipe_id_arg(args)

      :error ->
        case Enum.find(ws.proposed, &({&1.date, &1.slot} == key)) do
          nil -> {:error, "no_meal_to_keep", %{}}
          meal -> {:ok, meal.recipe_id}
        end
    end
  end

  defp not_excluded(ws, recipe_id) do
    if MapSet.member?(ws.excluded, recipe_id),
      do: {:error, "recipe_excluded", %{}},
      else: :ok
  end

  defp pinnable_recipe(ctx, ws, recipe_id, {_date, slot}) do
    case RecipeSearch.lookup(ctx.household, [recipe_id]) do
      {:ok, %{^recipe_id => {:safe, recipe}}} ->
        if slot in recipe.slots, do: {:ok, recipe}, else: {:error, "recipe_not_for_slot", %{}}

      {:ok, %{^recipe_id => {:restricted, _recipe}}} ->
        {:error, "restriction_conflict", %{"replacements" => replacements(ctx, ws, slot)}}

      {:ok, _none} ->
        {:error, "recipe_not_found", %{}}

      {:error, :search_failed} ->
        {:error, "search_failed", %{}}
    end
  end

  # Safe recipes of the same slot the agent can offer instead; Restrictions
  # are already excluded by the search.
  defp replacements(ctx, ws, slot) do
    filters = %{
      slot: slot,
      exclude_recipe_ids: MapSet.to_list(ws.excluded),
      limit: @replacement_limit
    }

    case RecipeSearch.search(ctx.household, filters) do
      {:ok, recipes} -> Enum.map(recipes, &%{"recipe_id" => &1.id, "name" => &1.name})
      {:error, :search_failed} -> []
    end
  end

  defp cast_uuid(value) when is_binary(value), do: Ecto.UUID.cast(value)
  defp cast_uuid(_value), do: :error

  defp pin_data({date, slot}, recipe),
    do: %{
      "date" => Date.to_iso8601(date),
      "slot" => slot,
      "recipe_id" => recipe.id,
      "name" => recipe.name
    }

  defp key_data({date, slot}), do: %{"date" => Date.to_iso8601(date), "slot" => slot}

  defp meal_key_data(meal),
    do: %{
      "date" => Date.to_iso8601(meal.date),
      "slot" => meal.slot,
      "recipe_id" => meal.recipe_id
    }

  defp slot_order(ctx), do: ctx.slots |> Enum.with_index() |> Map.new()

  defp sort_key({date, slot}, order), do: {Date.to_iso8601(date), Map.get(order, slot, 99)}
end
