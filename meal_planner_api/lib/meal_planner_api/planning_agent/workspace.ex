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
    * `must_change` — the Released Meals released one by one: the household
      asked to change them, so the next `run_optimizer` avoids their previous
      recipe on that day and slot (issue #148). "Redo the whole week"
      (`release_all`) releases without forcing a change
    * `variety_cap` — the session's variety cap
    * `recipe_drafts` — Recipe Drafts by id (`MealPlannerApi.PlanningAgent.RecipeDraft`)
    * `deviation_approval` / `absence_exceptions` — human-owned approvals,
      set only by the Member through `MealPlannerApi.PlanningAgent.Session`
    * `price_refreshes` — recent live price refreshes by ingredient id
      (`MealPlannerApi.PlanningAgent.Prices.refresh_memo/0`), so the session
      does not scrape the same Ingredient again on every `lookup_prices`
    * `session_brands` — Session Brands by ingredient id
      (`%{ingredient: name, brand: brand}`), set with `set_session_brand`:
      they override the Household's Brand Preference for this session only
      and are discarded with it
    * `guests` — `{date, slot} => %{count, restrictions}`, set with
      `set_guests` (`MealPlannerApi.PlanningAgent.Diners`): every meal is
      scaled to its diners, and a guest restriction the household
      volunteered binds that meal only
    * `skipped` — `{date, slot}` meals the Household does not eat at home
      (issue #160), set with `skip` / `unskip`: they are out of the range,
      never planned, bought or saved. A skip covers the whole meal for the
      Household, unlike an Absence Exception, which lifts one Restriction
      of one Member
    * `budget_conflict` — the cause of the budget Deviation of the last
      Proposal, while the household has not answered it: AI-created Recipe
      Drafts are refused until their next message (issue #148)

  `edit/3` applies one edit or refuses it with a reason; approvals are human
  actions and can never be set here.
  """

  alias MealPlannerApi.Optimization.Variety
  alias MealPlannerApi.PlanningAgent.{Diners, RecipeDraft, RecipeSearch}

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
            must_change: MapSet.new(),
            variety_cap: 2,
            recipe_drafts: %{},
            deviation_approval: nil,
            absence_exceptions: [],
            price_refreshes: %{},
            session_brands: %{},
            guests: %{},
            skipped: MapSet.new(),
            budget_conflict: nil

  @type key :: {Date.t(), String.t()}
  @type t :: %__MODULE__{
          draft: [map()] | nil,
          proposal: map() | nil,
          proposed: [map()],
          pins: %{key() => %{recipe_id: Ecto.UUID.t(), name: String.t()}},
          excluded: MapSet.t(Ecto.UUID.t()),
          released: MapSet.t(key()),
          must_change: MapSet.t(key()),
          variety_cap: pos_integer(),
          recipe_drafts: %{Ecto.UUID.t() => term()},
          deviation_approval: map() | nil,
          absence_exceptions: [map()],
          price_refreshes: MealPlannerApi.PlanningAgent.Prices.refresh_memo(),
          session_brands: %{Ecto.UUID.t() => %{ingredient: String.t(), brand: String.t()}},
          guests: %{key() => Diners.guests()},
          skipped: MapSet.t(key()),
          budget_conflict: map() | nil
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

  An edit that changes the Workspace discards the draft: it was planned
  without that edit, so `present_proposal` needs a new `run_optimizer` first.
  """
  @spec edit(t(), map(), ctx()) :: {:ok, t(), map()} | {:error, String.t(), map()}
  def edit(%__MODULE__{} = ws, args, ctx) do
    case apply_edit(ws, args, ctx) do
      {:ok, ^ws, result} -> {:ok, ws, result}
      {:ok, edited, result} -> {:ok, %{edited | draft: nil}, result}
      error -> error
    end
  end

  defp apply_edit(ws, args, ctx) do
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
      action == "set_guests" -> set_guests(ws, args, ctx)
      action == "skip" -> skip(ws, args, ctx)
      action == "unskip" -> unskip(ws, args, ctx)
      true -> {:error, "unknown_action", %{}}
    end
  end

  @doc "The human-facing reason of an edit refusal code."
  @spec reason(String.t()) :: String.t()
  def reason("approval_not_allowed"),
    do: "Approvals and confirmations are made only by the household in the app."

  def reason("unknown_action"),
    do:
      "Use pin, unpin, exclude, include, release, release_all, set_variety_cap, set_guests, " <>
        "skip or unskip."

  def reason("invalid_date"), do: "The date must be an ISO date (YYYY-MM-DD)."
  def reason("date_outside_range"), do: "The date is outside the Planning Range."
  def reason("unknown_slot"), do: "The slot is not planned in this session."
  def reason("invalid_recipe_id"), do: "The recipe id is not valid."
  def reason("recipe_not_found"), do: "No recipe with this id is available to the household."
  def reason("recipe_not_for_slot"), do: "This recipe does not suit that meal slot."

  def reason("recipe_not_plannable"),
    do: "A dictated Recipe Draft cannot be planned until the Member saves it."

  def reason("restriction_conflict"),
    do:
      "This recipe conflicts with a household Restriction and cannot be pinned. " <>
        "Pick one of the safe replacements yourself, plan and present the Proposal, then " <>
        "tell the household what changed and why. Do not ask before presenting."

  def reason("recipe_excluded"), do: "The recipe is excluded in this session; include it first."
  def reason("recipe_pinned"), do: "The recipe is pinned; unpin it first."
  def reason("no_meal_to_keep"), do: "There is no proposed meal there to keep; name a recipe."
  def reason("not_pinned"), do: "No Pin exists for that day and slot."
  def reason("not_skipped"), do: "That day and slot is not skipped."
  def reason("no_proposal"), do: "There is no Proposal yet; run the optimizer and present one."
  def reason("no_proposed_meal"), do: "The last Proposal has no meal for that day and slot."
  def reason("meal_pinned"), do: "That meal is pinned; unpin it before releasing it."
  def reason("search_failed"), do: "The recipe lookup failed; try again."

  def reason("invalid_guests"),
    do: "guests must be an integer from 0 to #{Diners.max_guests()} (0 clears them)."

  def reason("invalid_guest_restriction"),
    do: "guest_restrictions accepts only: #{Enum.join(Diners.restriction_names(), ", ")}."

  def reason("guest_restrictions_need_guests"),
    do: "Guest restrictions need at least one guest at that meal."

  def reason("invalid_variety_cap"),
    do: "The variety cap must be an integer from 1 to #{@max_variety_cap}."

  @doc """
  The skipped meals of a Workspace, or of a session or tool context
  (`ctx.skipped`, else its Workspace's). Snapshots stored before #160 lack
  the field: nothing is skipped.
  """
  @spec skipped(t() | map()) :: MapSet.t(key())
  def skipped(%{skipped: %MapSet{} = skipped}), do: skipped
  def skipped(%{workspace: workspace}), do: skipped(workspace)
  def skipped(_ws_or_ctx), do: MapSet.new()

  @doc "Skipped meals as `{date, slot}` data, in date and `slots` order."
  @spec skipped_data(MapSet.t(key()), [String.t()]) :: [map()]
  def skipped_data(skipped, slots) do
    order = slots |> Enum.with_index() |> Map.new()

    skipped
    |> Enum.sort_by(&sort_key(&1, order))
    |> Enum.map(&key_data/1)
  end

  @doc """
  The meals the optimizer must keep: every Pin plus, once a Proposal exists,
  each of its meals that was not released. A skipped meal is never kept.
  """
  @spec fixed_meals(t()) :: [%{date: Date.t(), slot: String.t(), recipe_id: Ecto.UUID.t()}]
  def fixed_meals(%__MODULE__{} = ws) do
    skipped = skipped(ws)

    kept =
      for meal <- ws.proposed,
          key = {meal.date, meal.slot},
          not MapSet.member?(ws.released, key),
          not Map.has_key?(ws.pins, key),
          not MapSet.member?(skipped, key),
          into: %{},
          do: {key, meal.recipe_id}

    pins =
      for {key, pin} <- ws.pins,
          not MapSet.member?(skipped, key),
          into: %{},
          do: {key, pin.recipe_id}

    kept
    |> Map.merge(pins)
    |> Enum.map(fn {{date, slot}, recipe_id} ->
      %{date: date, slot: slot, recipe_id: recipe_id}
    end)
    |> Enum.sort_by(&{Date.to_iso8601(&1.date), &1.slot})
  end

  @doc """
  The Released Meals the household asked to change, each with the recipe of
  the last Proposal it must not keep: the next `run_optimizer` avoids that
  recipe on that day and slot only.
  """
  @spec avoided_meals(t()) :: [%{date: Date.t(), slot: String.t(), recipe_id: Ecto.UUID.t()}]
  def avoided_meals(%__MODULE__{} = ws) do
    must_change = Map.get(ws, :must_change, MapSet.new())
    skipped = skipped(ws)

    for meal <- ws.proposed,
        key = {meal.date, meal.slot},
        not MapSet.member?(skipped, key),
        MapSet.member?(must_change, key),
        MapSet.member?(ws.released, key),
        not Map.has_key?(ws.pins, key) do
      %{date: meal.date, slot: meal.slot, recipe_id: meal.recipe_id}
    end
    |> Enum.sort_by(&{Date.to_iso8601(&1.date), &1.slot})
  end

  @doc """
  Voids the shown Proposal (it failed revalidation): its meals stop being
  the base of the next re-optimization, so nothing but the Pins stays fixed.
  """
  @spec void_proposal(t()) :: t()
  def void_proposal(%__MODULE__{} = ws),
    do:
      Map.put(
        %{ws | proposal: nil, proposed: [], released: MapSet.new()},
        :must_change,
        MapSet.new()
      )

  @doc """
  Records a valid Proposal: its meals become the base of the next
  re-optimization and no meal is released any more.
  """
  @spec present(t(), map(), [map()]) :: t()
  def present(%__MODULE__{} = ws, proposal, meals) do
    proposed = Enum.map(meals, &Map.take(&1, [:date, :slot, :recipe_id, :name]))
    # Snapshots stored before #148 lack `must_change`, hence `Map.put`.
    ws = %{ws | proposal: proposal, proposed: proposed, released: MapSet.new()}
    Map.put(ws, :must_change, MapSet.new())
  end

  @doc "Renames the Pins of `recipe_id`, after its Recipe Draft was revised."
  @spec rename_pins(t(), Ecto.UUID.t(), String.t()) :: t()
  def rename_pins(%__MODULE__{} = ws, recipe_id, name) do
    pins =
      Map.new(ws.pins, fn
        {key, %{recipe_id: ^recipe_id} = pin} -> {key, %{pin | name: name}}
        other -> other
      end)

    %{ws | pins: pins}
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
      "variety_cap" => ws.variety_cap,
      "guests" =>
        ws
        |> Map.get(:guests, %{})
        |> Enum.sort_by(fn {key, _guests} -> sort_key(key, order) end)
        |> Enum.map(fn {key, guests} -> Diners.data(key, guests) end),
      "skipped" => ws |> skipped() |> skipped_data(ctx.slots)
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
          must_change = ws |> Map.get(:must_change, MapSet.new()) |> MapSet.put(key)
          ws = Map.put(%{ws | released: MapSet.put(ws.released, key)}, :must_change, must_change)

          {:ok, ws, %{"status" => "ok", "must_change" => true}}
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

  # Guests of one meal (issue #152). A change of guest restrictions releases
  # the proposed meal there, so the next `run_optimizer` may replace a recipe
  # they forbid; a Pin stays and is checked by `present_proposal`.
  defp set_guests(ws, args, ctx) do
    with {:ok, key} <- meal_key(args, ctx),
         {:ok, guests} <- guests_arg(args) do
      all = Map.get(ws, :guests, %{})
      before = all |> Map.get(key, %{restrictions: []}) |> Map.fetch!(:restrictions)
      now = if guests, do: guests.restrictions, else: []

      released =
        if before != now and not Map.has_key?(ws.pins, key) and
             Enum.any?(ws.proposed, &({&1.date, &1.slot} == key)),
           do: MapSet.put(ws.released, key),
           else: ws.released

      all = if guests, do: Map.put(all, key, guests), else: Map.delete(all, key)
      ws = Map.put(%{ws | released: released}, :guests, all)

      {:ok, ws,
       %{
         "status" => "ok",
         "guests" => Diners.data(key, guests || %{count: 0, restrictions: []})
       }}
    end
  end

  # A meal the Household does not eat at home (issue #160). The whole meal is
  # left out for the Household; a Pin there is removed, since the household
  # just said nobody eats that meal at home.
  defp skip(ws, args, ctx) do
    with {:ok, key} <- meal_key(args, ctx) do
      pinned? = Map.has_key?(ws.pins, key)

      ws =
        ws
        |> Map.merge(%{
          pins: Map.delete(ws.pins, key),
          released: MapSet.delete(ws.released, key),
          must_change: ws |> Map.get(:must_change, MapSet.new()) |> MapSet.delete(key)
        })
        |> Map.put(:skipped, ws |> skipped() |> MapSet.put(key))

      {:ok, ws, %{"status" => "ok", "skipped" => key_data(key), "unpinned" => pinned?}}
    end
  end

  defp unskip(ws, args, ctx) do
    with {:ok, key} <- meal_key(args, ctx) do
      skipped = skipped(ws)

      if MapSet.member?(skipped, key),
        do:
          {:ok, Map.put(ws, :skipped, MapSet.delete(skipped, key)),
           %{"status" => "ok", "unskipped" => key_data(key)}},
        else: {:error, "not_skipped", %{}}
    end
  end

  defp guests_arg(args) do
    case Diners.parse(args) do
      {:ok, guests} -> {:ok, guests}
      {:error, code} -> {:error, code, %{}}
    end
  end

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

  # A Recipe Draft of this Workspace is pinned like a stored recipe (issue
  # #154): only an AI-created Draft is plannable, it must suit the slot, and
  # it is checked again against the household's and the meal's guests'
  # Restrictions.
  defp pinnable_recipe(ctx, ws, recipe_id, {date, slot}) do
    case Map.fetch(Map.get(ws, :recipe_drafts, %{}), recipe_id) do
      {:ok, draft} -> pinnable_draft(ctx, ws, draft, {date, slot})
      :error -> pinnable_stored(ctx, ws, recipe_id, {date, slot})
    end
  end

  defp pinnable_draft(ctx, ws, draft, {date, slot}) do
    cond do
      not RecipeDraft.plannable?(draft) ->
        {:error, "recipe_not_plannable", %{}}

      slot not in draft.slots ->
        {:error, "recipe_not_for_slot", %{}}

      RecipeDraft.restricted?(draft, ctx.household) or
          guest_conflict?(ctx, ws, %{date: date, slot: slot, recipe_id: draft.id}) ->
        {:error, "restriction_conflict", %{"replacements" => replacements(ctx, ws, date, slot)}}

      true ->
        {:ok, draft}
    end
  end

  defp pinnable_stored(ctx, ws, recipe_id, {date, slot}) do
    case RecipeSearch.lookup(ctx.household, [recipe_id]) do
      {:ok, %{^recipe_id => {:safe, recipe}}} ->
        cond do
          slot not in recipe.slots ->
            {:error, "recipe_not_for_slot", %{}}

          guest_conflict?(ctx, ws, %{date: date, slot: slot, recipe_id: recipe_id}) ->
            {:error, "restriction_conflict",
             %{"replacements" => replacements(ctx, ws, date, slot)}}

          true ->
            {:ok, recipe}
        end

      {:ok, %{^recipe_id => {:restricted, _recipe}}} ->
        {:error, "restriction_conflict", %{"replacements" => replacements(ctx, ws, date, slot)}}

      {:ok, _none} ->
        {:error, "recipe_not_found", %{}}

      {:error, :search_failed} ->
        {:error, "search_failed", %{}}
    end
  end

  defp guest_conflict?(ctx, ws, meal),
    do: Diners.conflicts([meal], Map.put(ctx, :workspace, ws)) != []

  # Safe recipes of the same slot the agent can offer instead; Restrictions
  # are already excluded by the search, guest restrictions of the meal here.
  defp replacements(ctx, ws, date, slot) do
    filters = %{
      slot: slot,
      exclude_recipe_ids: MapSet.to_list(ws.excluded),
      limit: @replacement_limit * 2
    }

    case RecipeSearch.search(ctx.household, filters) do
      {:ok, recipes} ->
        recipes
        |> Enum.reject(&guest_conflict?(ctx, ws, %{date: date, slot: slot, recipe_id: &1.id}))
        |> Enum.take(@replacement_limit)
        |> Enum.map(&%{"recipe_id" => &1.id, "name" => &1.name})

      {:error, :search_failed} ->
        []
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
