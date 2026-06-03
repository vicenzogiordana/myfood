# SDD Design: MealPlannerApi — Full Architecture Redo

## Change Summary

Technical design for implementing 3-layer architecture with GenServer+Port optimizer, injected ports, and pure data access.

---

## 1. GenServer + Port: OptimizerServer

### 1.1 State Machine

```
                                    ┌─────────────┐
                                    │  :starting  │
                                    │  (spawning) │
                                    └──────┬──────┘
                                           │ :python_ready
                                           ▼
  ┌────────────────────────────────────────────────────┐
  │                     :running                       │
  │  - port: Port reference                           │
  │  - python_pid: PID                                 │
  │  - circuit_state: :closed                          │
  │  - consecutive_failures: 0                         │
  └────────────────────┬─────────────────────────────┘
                       │
         ┌─────────────┼─────────────┐
         │             │             │
    :python_exit   :circuit_open  :reset
         │             │             │
         ▼             ▼             ▼
  ┌──────────┐  ┌───────────┐  ┌────────────┐
  │ :dead    │  │ :open     │  │ :half_open │
  └────┬─────┘  └─────┬─────┘  └──────┬─────┘
       │              │               │
  :restart          :reset        :circuit_open
       │              │               │  or
       └──────────────┴───────────────┘ :python_ready
```

### 1.2 Port Communication

**Spawn Python process**:
```elixir
port = Port.open({:spawn_executable, python_executable}, [
  :binary,
  :exit_status,
  :use_stdio,
  :stderr_to_stdout,
  {:arg0, script_path}
])
```

**Startup handshake**:
```elixir
# Send:
send(port, {self(), {:command, ~s({"type":"handshake","version":"1.0"}\n)}})

# Expect in handle_info:
{:port, {:data, ~s({"type":"ready","version":"1.0"}\n)}} -> 
  {:noreply, %{state | status: :running}}
```

**Request/Response protocol**:
```
Elixir                          Python
   │                               │
   │── {"type":"solve",───────────►│
   │    "id":"req-001",            │
   │    "payload":{...}}          │
   │                               │
   │◄── {"type":"solution",───────│
   │    "id":"req-001",           │
   │    "result":{"meals":[...]}} │
   │                               │
   │── {"type":"solve",───────────►│
   │    "id":"req-002",            │
   │    "payload":{...}}          │
   │                               │
   │◄── {"type":"error",──────────│
   │    "id":"req-002",           │
   │    "error":"timeout"}        │
```

### 1.3 Circuit Breaker Implementation

```elixir
defmodule MealPlannerApi.Optimization.OptimizerServer do
  use GenServer

  @circuit_closed  :closed
  @circuit_half_open :half_open
  @circuit_open    :open

  defmodule State do
    defstruct [
      :port,
      :python_pid,
      circuit_state: :closed,
      consecutive_failures: 0,
      last_failure_at: nil,
      pending_requests: %{},        # request_id => from()
      next_request_id: 1
    ]
  end

  # --- Circuit Breaker Logic ---

  defp record_failure(state) do
    new_failures = state.consecutive_failures + 1
    
    if new_failures >= circuit_failure_threshold() do
      # Open circuit
      schedule_circuit_reset()
      %{state | 
        consecutive_failures: new_failures,
        circuit_state: @circuit_open,
        last_failure_at: DateTime.utc_now()}
    else
      %{state | 
        consecutive_failures: new_failures,
        last_failure_at: DateTime.utc_now()}
    end
  end

  defp record_success(state) do
    %{state | 
      consecutive_failures: 0,
      circuit_state: @circuit_closed}
  end

  defp circuit_open?(state), do: state.circuit_state == @circuit_open

  defp attempt_circuit_reset(state) do
    elapsed_ms = 
      case state.last_failure_at do
        nil -> :infinity
        dt -> DateTime.diff(DateTime.utc_now(), dt, :millisecond)
      end

    if elapsed_ms >= circuit_reset_timeout_ms() do
      %{state | circuit_state: @circuit_half_open}
    else
      state
    end
  end
end
```

### 1.4 Request Handling

```elixir
def handle_call({:solve, payload}, from, state) do
  cond do
    circuit_open?(state) ->
      # Use fallback immediately
      fallback_result = OptimizerFallback.select_weekly_menu(payload)
      {:reply, fallback_result, state}

    state.port == nil ->
      {:reply, {:error, :optimizer_unavailable}, state}

    true ->
      # Queue request and send to Python
      request_id = next_request_id(state)
      new_state = enqueue_request(state, request_id, from, payload)
      send_solve_request(new_state, request_id, payload)
      {:noreply, new_state}
  end
end

defp send_solve_request(state, request_id, payload) do
  message = Jason.encode!(%{
    "type" => "solve",
    "id" => request_id,
    "payload" => payload
  })
  Port.command(state.port, message <> "\n")
end

def handle_info({:port, {:data, raw}}, state) do
  case Jason.decode(raw) do
    {:ok, %{"type" => "solution", "id" => id, "result" => result}} ->
      complete_request(state, id, {:ok, result})
    
    {:ok, %{"type" => "error", "id" => id, "error" => error}} ->
      complete_request(state, id, {:error, {:optimizer_error, error}})
    
    {:ok, %{"type" => "ready"}} ->
      {:noreply, %{state | status: :running}}
    
    _ ->
      {:noreply, state}
  end
end
```

### 1.5 Process Supervision

```elixir
# In application.ex
children = [
  # ... other children ...
  {MealPlannerApi.Optimization.OptimizerServer, []}
]

# Supervisor strategy: one_for_one
# OptimizerServer has its own internal restart logic
```

**Restart strategy**: `GenServer.start_link` with `:permanent` supervision. If Python crashes, GenServer restarts and re-spawns Python.

---

## 2. OptimizerFallback

### 2.1 Greedy Heuristic Algorithm

```elixir
defmodule MealPlannerApi.Optimization.OptimizerFallback do
  @slots [:breakfast, :lunch, :dinner]

  def select_weekly_menu(payload) do
    %{^"days" => days, "candidates_by_slot" => candidates_by_slot} = payload
    
    meals = 
      Enum.flat_map(days, fn day ->
        Enum.map(@slots, fn slot ->
          slot_str = Atom.to_string(slot)
          candidates = Map.get(candidates_by_slot, slot_str, [])
          
          selected = greedy_select(candidates)
          
          %{
            "day" => day,
            "slot" => slot_str,
            "recipe_id" => selected["recipe_id"]
          }
        end)
      end)
    
    {:ok, %{"meals" => meals}}
  end

  defp greedy_select(candidates) when is_list(candidates) do
    candidates
    |> Enum.reject(&is_nil(&1["recipe_id"]))
    |> Enum.sort_by(&(&1["estimated_cost_cents"]), :asc)
    |> List.first()
    |> then(fn 
      nil -> %{"recipe_id" => nil, "slot" => nil}
      c -> c
    end)
  end
end
```

---

## 3. Port Behaviours

### 3.1 OptimizerPort

```elixir
defmodule MealPlannerApi.Optimization.OptimizerPort do
  @type optimizer_payload :: map()
  @type optimizer_result :: {:ok, %{meals: [map()]}} | {:error, term()}

  @callback select_weekly_menu(optimizer_payload()) :: optimizer_result()
  @callback health_check() :: :ok | {:error, term()}
end
```

**Implementations**:
1. `OptimizerServer` — production, GenServer+Port
2. `OptimizerFallback` — fallback only (no port)
3. `OptimizerMock` — for testing

### 3.2 AIPort

```elixir
defmodule MealPlannerApi.AI.AIPort do
  @callback generate_text(prompt :: String.t(), opts :: keyword()) :: 
    {:ok, String.t()} | {:error, term()}
  
  @callback stream_chat(prompt :: String.t(), topic :: String.t(), opts :: keyword()) :: 
    :ok | {:error, term()}
end
```

**Implementations**:
1. `GeminiAdapter` — wraps existing GeminiClient
2. `AIMock` — for testing

### 3.3 VoiceParserPort

```elixir
defmodule MealPlannerApi.Voice.VoiceParserPort do
  @type inventory_item :: %{id: String.t(), name: String.t(), quantity_milli: integer()}
  @type parsed_op :: %{inventory_item_id: String.t(), quantity_milli: integer()}

  @callback parse(String.t(), [inventory_item()]) :: 
    {:ok, [parsed_op()]} | {:error, term()}
end
```

**Implementations**:
1. `AIVoiceParser` — uses `AIPort.generate_text/2`
2. `RuleBasedVoiceParser` — pure regex

---

## 4. Dependency Injection Setup

### 4.1 Application Config

```elixir
# runtime.exs
config :meal_planner_api,
  optimizer_port: MealPlannerApi.Optimization.OptimizerServer,
  ai_port: MealPlannerApi.AI.GeminiAdapter,
  voice_parser: MealPlannerApi.Voice.AIVoiceParser  # or RuleBasedVoiceParser
```

### 4.2 Service Initialization

```elixir
defmodule MealPlannerApi.Planning.PlanningService do
  # Inject via start_link args or application env
  def start_link(opts) do
    optimizer = Keyword.get(opts, :optimizer, optimizer_from_config())
    GenServer.start_link(__MODULE__, %{optimizer: optimizer}, name: __MODULE__)
  end

  defp optimizer_from_config do
    Application.get_env(:meal_planner_api, :optimizer_port, 
      MealPlannerApi.Optimization.OptimizerServer)
  end
end
```

**Alternative: Explicit dependency passing (preferred for testability)**:

```elixir
defmodule MealPlannerApi.Planning.PlanningService do
  defstruct [:optimizer, :recipe_repo, :planning_repo]

  def new(opts) do
    struct(__MODULE__, [
      optimizer: opts[:optimizer] || optimizer_from_config(),
      recipe_repo: opts[:recipe_repo] || RecipeRepo,
      planning_repo: opts[:planning_repo] || PlanningRepo
    ])
  end

  # Functional API (preferred for services that don't need state)
  def build_weekly_plan(%__MODULE__{} = service, user, params) do
    # Use service.optimizer, service.recipe_repo, etc.
  end
end
```

---

## 5. Struct Definitions

### 5.1 WeeklyPlan

```elixir
defmodule MealPlannerApi.Planning.WeeklyPlan do
  @type t :: %__MODULE__{
    account_type: :individual | :group,
    subscription_tier: :free | :premium,
    days: [DayPlan.t()],
    notes: [String.t()],
    budget: Budget.t(),
    budget_within_limit: boolean(),
    estimated_total_cost_cents: integer(),
    inventory_items: [String.t()],
    max_planning_days: pos_integer()
  }

  defstruct [
    :account_type,
    :subscription_tier,
    :days,
    :notes,
    :budget,
    :budget_within_limit,
    :estimated_total_cost_cents,
    :inventory_items,
    :max_planning_days
  ]

  @type t :: %__MODULE__{}
end

defmodule MealPlannerApi.Planning.DayPlan do
  @type t :: %__MODULE__{
    day: String.t(),          # "monday", "tuesday", etc.
    meals: [MealCandidate.t()]
  }

  defstruct [:day, :meals]
end

defmodule MealPlannerApi.Planning.MealCandidate do
  @type t :: %__MODULE__{
    recipe_id: String.t() | nil,
    slot: :breakfast | :lunch | :dinner,
    label: String.t(),
    kcal: float(),
    estimated_cost_cents: integer(),
    inventory_hit_count: non_neg_integer(),
    protein_g_per_serving: float(),
    carbs_g_per_serving: float(),
    fat_g_per_serving: float()
  }

  defstruct [
    :recipe_id,
    :slot,
    :label,
    :kcal,
    :estimated_cost_cents,
    :inventory_hit_count,
    :protein_g_per_serving,
    :carbs_g_per_serving,
    :fat_g_per_serving
  ]
end

defmodule MealPlannerApi.Planning.Budget do
  @type t :: %__MODULE__{
    account_id: String.t() | nil,
    weekly_limit_cents: non_neg_integer(),
    currency: String.t()
  }

  defstruct [:account_id, :weekly_limit_cents, :currency]
end
```

### 5.2 InventoryItem (for voice parsing)

```elixir
defmodule MealPlannerApi.Inventory.InventoryItemView do
  @type t :: %__MODULE__{
    id: String.t(),
    ingredient_id: String.t(),
    ingredient_name: String.t(),
    category: String.t(),
    quantity_milli: integer(),
    unit: String.t(),
    freshness_status: :ok | :warning | :expired
  }

  defstruct [:id, :ingredient_id, :ingredient_name, :category, 
             :quantity_milli, :unit, :freshness_status]
end
```

---

## 6. Service Implementations

### 6.1 PlanningService (Functional style)

```elixir
defmodule MealPlannerApi.Planning.PlanningService do
  alias MealPlannerApi.Planning.{
    WeeklyPlan, DayPlan, MealCandidate, Budget
  }
  alias MealPlannerApi.Persistence.{RecipeRepo, PlanningRepo}
  alias MealPlannerApi.Optimization.OptimizerPort

  defstruct [:optimizer, :recipe_repo, :planning_repo]

  # Functional API (no GenServer state needed for orchestration)
  def build_weekly_plan(%__MODULE__{} = service, user, params) do
    with {:ok, ids} <- resolve_identity(user),
         {:ok, max_days} <- resolve_max_days(ids),
         {:ok, days} <- resolve_days(params, max_days),
         kcal <- parse_int(params["kcal_target"], 2100),
         budget <- resolve_budget(user, params),
         candidates_by_slot <- load_candidates(service, ids, kcal),
         payload <- build_payload(days, kcal, budget, candidates_by_slot),
         {:ok, result} <- call_optimizer(service.optimizer, payload),
         day_plans <- parse_result(result, days, candidates_by_slot) do
      
      estimated_cost = calculate_cost(day_plans)
      
      {:ok, %WeeklyPlan{
        account_type: Map.get(user, :account_type, :individual),
        subscription_tier: Map.get(user, :subscription_tier, :free),
        days: day_plans,
        notes: build_notes(budget, estimated_cost, day_plans),
        budget: budget,
        budget_within_limit: estimated_cost <= budget.weekly_limit_cents,
        estimated_total_cost_cents: estimated_cost,
        inventory_items: [],
        max_planning_days: max_days
      }}
    end
  end

  # Private helpers
  defp call_optimizer(optimizer, payload) do
    optimizer.select_weekly_menu(payload)
  end

  defp load_candidates(service, ids, kcal) do
    [:breakfast, :lunch, :dinner]
    |> Enum.map(fn slot ->
      recipes = service.recipe_repo.list_for_slot(ids.account_id, slot)
      candidates = Enum.map(recipes, &to_candidate(&1, slot, kcal))
      {slot, candidates}
    end)
    |> Map.new()
  end

  defp to_candidate(recipe, slot, kcal_target) do
    %MealCandidate{
      recipe_id: recipe.id,
      slot: slot,
      label: recipe.name,
      kcal: recipe.calories_per_serving || default_kcal(slot, kcal_target),
      estimated_cost_cents: recipe.estimated_cost_cents || 3000,
      inventory_hit_count: 0,
      protein_g_per_serving: to_float(recipe.protein_g_per_serving),
      carbs_g_per_serving: to_float(recipe.carbs_g_per_serving),
      fat_g_per_serving: to_float(recipe.fat_g_per_serving)
    }
  end

  defp default_kcal(:breakfast, target), do: trunc(target * 0.25)
  defp default_kcal(:lunch, target), do: trunc(target * 0.35)
  defp default_kcal(:dinner, target), do: trunc(target * 0.30)
  defp default_kcal(_, target), do: trunc(target * 0.33)

  defp to_float(nil), do: 0.0
  defp to_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp to_float(v) when is_number(v), do: v * 1.0
  defp to_float(_), do: 0.0

  defp parse_result(%{"meals" => meals}, days, candidates_by_slot) do
    by_day = Enum.group_by(meals, & &1["day"])
    
    Enum.map(days, fn day ->
      day_meals = Map.get(by_day, day, [])
      %DayPlan{
        day: day,
        meals: resolve_day_meals(day_meals, candidates_by_slot)
      }
    end)
  end

  defp resolve_day_meals(meal_results, candidates_by_slot) do
    [:breakfast, :lunch, :dinner]
    |> Enum.map(fn slot ->
      found = Enum.find(meal_results, &(&1["slot"] == Atom.to_string(slot)))
      
      cond do
        found && found["recipe_id"] ->
          find_candidate(candidates_by_slot, slot, found["recipe_id"])
        true ->
          List.first(Map.get(candidates_by_slot, slot, [])) || fallback_candidate(slot)
      end
    end)
  end

  defp find_candidate(candidates_by_slot, slot, recipe_id) do
    candidates = Map.get(candidates_by_slot, slot, [])
    Enum.find(candidates, &(&1.recipe_id == recipe_id)) || fallback_candidate(slot)
  end

  defp fallback_candidate(slot) do
    %MealCandidate{
      recipe_id: nil,
      slot: slot,
      label: fallback_label(slot),
      kcal: 500,
      estimated_cost_cents: 3000,
      inventory_hit_count: 0,
      protein_g_per_serving: 0.0,
      carbs_g_per_serving: 0.0,
      fat_g_per_serving: 0.0
    }
  end

  defp fallback_label(:breakfast), do: "breakfast suggestion"
  defp fallback_label(:lunch), do: "protein lunch"
  defp fallback_label(:dinner), do: "light dinner"
end
```

### 6.2 InventoryService

```elixir
defmodule MealPlannerApi.Inventory.InventoryService do
  alias MealPlannerApi.Inventory.InventoryItemView
  alias MealPlannerApi.Persistence.InventoryRepo
  alias MealPlannerApi.Voice.VoiceParserPort

  defstruct [:voice_parser, :inventory_repo]

  def new(opts) do
    struct(__MODULE__, [
      voice_parser: opts[:voice_parser] || voice_from_config(),
      inventory_repo: opts[:inventory_repo] || InventoryRepo
    ])
  end

  def get_inventory_view(%__MODULE__{} = service, user) do
    with {:ok, ids} <- resolve_identity(user) do
      items = service.inventory_repo.list_with_ingredient(ids.account_id)
      
      decorated = Enum.map(items, &decorate_item/1)
      
      {:ok, %{
        sections: %{
          ok: Enum.filter(decorated, &(&1.freshness_status == :ok)),
          warning: Enum.filter(decorated, &(&1.freshness_status == :warning)),
          expired: Enum.filter(decorated, &(&1.freshness_status == :expired))
        },
        by_category: group_by_category(decorated),
        totals: %{
          items_count: length(decorated),
          warning_count: Enum.count(decorated, &(&1.freshness_status == :warning)),
          expired_count: Enum.count(decorated, &(&1.freshness_status == :expired))
        }
      }}
    end
  end

  def voice_preview(%__MODULE__{} = service, user, text) do
    with {:ok, ids} <- resolve_identity(user),
         items <- service.inventory_repo.list_with_ingredient(ids.account_id),
         item_views <- Enum.map(items, &to_item_view/1),
         {:ok, ops} <- service.voice_parser.parse(text, item_views) do
      
      {:ok, %{
        raw_text: text,
        operations: ops,
        confirmation_required: true
      }}
    end
  end

  # Private
  defp decorate_item(item) do
    status = freshness_status(item)
    %InventoryItemView{
      id: item.id,
      ingredient_id: item.ingredient_id,
      ingredient_name: item.ingredient.name,
      category: Atom.to_string(item.ingredient.category),
      quantity_milli: item.quantity_milli,
      unit: Atom.to_string(item.unit),
      freshness_status: status
    }
  end

  defp freshness_status(item) do
    days = item.expired_at && Date.diff(item.expired_at, Date.utc_today()) || 999
    
    cond do
      days < 0 -> :expired
      days <= 2 -> :warning
      true -> :ok
    end
  end

  defp to_item_view(item) do
    %{
      id: item.id,
      name: item.ingredient.name,
      quantity_milli: item.quantity_milli
    }
  end
end
```

### 6.3 RuleBasedVoiceParser

```elixir
defmodule MealPlannerApi.Voice.RuleBasedVoiceParser do
  @behaviour MealPlannerApi.Voice.VoiceParserPort

  @patterns [
    ~r/mitad del kilo de (?<name>.+)/i,
    ~r/medio\s+(?<name>.+)/i,
    ~r/(?<name>\w+)/i
  ]

  @impl true
  def parse(text, items) do
    lowered = String.downcase(text)
    
    ops = 
      items
      |> Enum.reduce([], fn item, acc ->
        name = String.downcase(item.name)
        
        cond do
          String.contains?(lowered, "mitad del kilo de " <> name) ->
            [%{inventory_item_id: item.id, quantity_milli: 500} | acc]
          
          String.contains?(lowered, "medio " <> name) ->
            [%{inventory_item_id: item.id, quantity_milli: div(item.quantity_milli, 2)} | acc]
          
          String.contains?(lowered, name) ->
            [%{inventory_item_id: item.id, quantity_milli: max(div(item.quantity_milli, 4), 1)} | acc]
          
          true ->
            acc
        end
      end)
      |> Enum.reverse()

    {:ok, ops}
  end
end
```

---

## 7. Repository Pattern

### 7.1 RecipeRepo

```elixir
defmodule MealPlannerApi.Persistence.RecipeRepo do
  import Ecto.Query

  alias MealPlannerApi.Repo
  alias MealPlannerApi.Persistence.RecipeSchema

  @spec list_for_slot(binary(), atom()) :: [RecipeSchema.t()]
  def list_for_slot(account_id, slot) when is_binary(account_id) do
    from(r in RecipeSchema,
      where: is_nil(r.account_id) or r.account_id == ^account_id,
      where: ^slot in r.suitable_for_slots,
      order_by: [desc: r.inserted_at],
      preload: [recipe_ingredients: [:ingredient]]
    )
    |> Repo.all()
  end

  @spec list_by_ids([binary()]) :: [RecipeSchema.t()]
  def list_by_ids(ids) when is_list(ids) do
    from(r in RecipeSchema, where: r.id in ^ids)
    |> Repo.all()
  end

  @spec get_by_id(binary()) :: RecipeSchema.t() | nil
  def get_by_id(id) do
    Repo.get(RecipeSchema, id)
  end

  @spec list_with_ingredients(binary(), [binary()]) :: [RecipeSchema.t()]
  def list_with_ingredients(account_id, ingredient_ids) do
    from(r in RecipeSchema,
      join: ri in assoc(r, :recipe_ingredients),
      where: ri.ingredient_id in ^ingredient_ids,
      where: is_nil(r.account_id) or r.account_id == ^account_id,
      order_by: [desc: count(ri.id)],
      group_by: [r.id],
      limit: 10,
      preload: [recipe_ingredients: [:ingredient]]
    )
    |> Repo.all()
  end
end
```

---

## 8. Controller Implementation

### 8.1 PlanningController

```elixir
defmodule MealPlannerApiWeb.PlanningController do
  use MealPlannerApiWeb, :controller
  alias MealPlannerApi.Planning.PlanningService
  alias MealPlannerApi.Auth.Guardian

  action_fallback MealPlannerApiWeb.FallbackController

  def build_plan(conn, %{"planning" => planning_params}) do
    with {:ok, claims} <- Guardian.Plug.current_resource(conn),
         {:ok, user} <- build_user_map(claims),
         service = PlanningService.new([]),
         {:ok, plan} <- PlanningService.build_weekly_plan(service, user, planning_params) do
      
      conn
      |> put_status(:ok)
      |> json(PlanningService.serialize_plan(plan))
    end
  end

  def confirm_plan(conn, %{"meals" => meals}) do
    with {:ok, claims} <- Guardian.Plug.current_resource(conn),
         {:ok, user} <- build_user_map(claims),
         service = PlanningService.new([]),
         {:ok, result} <- PlanningService.confirm_plan(service, user, %{meals: meals}) do
      
      conn
      |> put_status(:ok)
      |> json(result)
    end
  end

  # Helpers
  defp build_user_map(claims) do
    {:ok, %{
      id: claims["sub"],
      account_id: claims["account_id"],
      account_type: String.to_atom(claims["account_type"]),
      subscription_tier: String.to_atom(claims["subscription_tier"])
    }}
  end
end
```

### 8.2 FallbackController (RFC 7807)

```elixir
defmodule MealPlannerApiWeb.FallbackController do
  use MealPlannerApiWeb, :controller

  def call(conn, {:error, :not_found}) do
    conn
    |> put_status(:not_found)
    |> put_view(json: MealPlannerApiWeb.ErrorJSON)
    |> render("error.json", type: "not-found", title: "Resource Not Found")
  end

  def call(conn, {:error, :unauthorized}) do
    conn
    |> put_status(:unauthorized)
    |> put_view(json: MealPlannerApiWeb.ErrorJSON)
    |> render("error.json", type: "unauthorized", title: "Unauthorized")
  end

  def call(conn, {:error, :invalid_payload}) do
    conn
    |> put_status(:bad_request)
    |> put_view(json: MealPlannerApiWeb.ErrorJSON)
    |> render("error.json", type: "invalid-payload", title: "Invalid Payload")
  end

  def call(conn, {:error, :optimizer_timeout}) do
    conn
    |> put_status(:service_unavailable)
    |> put_view(json: MealPlannerApiWeb.ErrorJSON)
    |> render("error.json", type: "optimizer-timeout", title: "Service Temporarily Unavailable")
  end

  def call(conn, {:error, reason}) do
    conn
    |> put_status(:unprocessable_entity)
    |> put_view(json: MealPlannerApiWeb.ErrorJSON)
    |> render("error.json", type: "validation-failed", title: "Validation Failed", detail: inspect(reason))
  end
end
```

### 8.3 ErrorJSON (RFC 7807)

```elixir
defmodule MealPlannerApiWeb.ErrorJSON do
  def error(%{type: type, title: title} = assigns) do
    %{
      type: "https://api.myfood.app/errors/#{type}",
      title: title,
      status: status_from_title(title),
      detail: Map.get(assigns, :detail, title),
      instance: Map.get(assigns, :instance, "/"),
      errors: Map.get(assigns, :errors, [])
    }
  end

  defp status_from_title("Resource Not Found"), do: 404
  defp status_from_title("Unauthorized"), do: 401
  defp status_from_title("Invalid Payload"), do: 400
  defp status_from_title("Service Temporarily Unavailable"), do: 503
  defp status_from_title("Validation Failed"), do: 422
  defp status_from_title(_), do: 500
end
```

---

## 9. Phoenix Router Updates

```elixir
defmodule MealPlannerApiWeb.Router do
  pipeline :api do
    plug :accepts, ["json"]
    plug CORSPlug, origin: "*"
  end

  pipeline :api_auth do
    plug :fetch_header
    plug :authenticate
  end

  scope "/api", MealPlannerApiWeb do
    pipe_through [:api, :api_auth]

    # Planning
    post "/planning/build", PlanningController, :build_plan
    post "/planning/confirm", PlanningController, :confirm_plan
    post "/planning/proposals/:id/confirm", PlanningController, :confirm_proposal
    post "/planning/proposals/:id/reject", PlanningController, :reject_proposal

    # Inventory
    get "/inventory", InventoryController, :index
    post "/inventory/items", InventoryController, :add_item
    patch "/inventory/items/:id", InventoryController, :adjust_item
    delete "/inventory/items/:id", InventoryController, :dispose_item
    post "/inventory/voice-preview", InventoryController, :voice_preview
    post "/inventory/voice-apply", InventoryController, :voice_apply

    # Accounts
    get "/accounts/me", AccountsController, :me

    # Calendar
    get "/calendar", CalendarController, :index

    # Cooking
    post "/cooking/sessions", CookingController, :create_session

    # Shopping
    get "/shopping", ShoppingController, :index
  end

  # Auth routes (no auth pipeline)
  scope "/api/auth", MealPlannerApiWeb do
    pipe_through :api
    post "/password", AuthController, :password
    post "/social", AuthController, :social
  end

  # Webhook routes (special handling)
  scope "/api/webhooks", MealPlannerApiWeb do
    pipe_through :api
    post "/revenuecat", RevenuecatController, :webhook
  end
end
```

---

## 10. Test Strategy

### 10.1 Port Tests

```elixir
defmodule MealPlannerApi.Optimization.OptimizerServerTest do
  use ExUnit.Case, async: false

  setup do
    # Start optimizer server with mock
    {:ok, server} = OptimizerServer.start_link(
      optimizer: OptimizerMock,
      test_mode: true
    )
    %{server: server}
  end

  test "selects weekly menu", %{server: server} do
    payload = build_valid_payload()
    
    result = GenServer.call(server, {:solve, payload})
    
    assert {:ok, %{"meals" => meals}} = result
    assert length(meals) == 21  # 7 days * 3 slots
  end

  test "circuit opens after 3 failures", %{server: server} do
    payload = build_valid_payload()
    
    Enum.each(1..3, fn _ ->
      GenServer.call(server, {:solve, %{invalid: true}})
    end)
    
    # Now circuit should be open, fallback used
    result = GenServer.call(server, {:solve, payload})
    assert {:ok, _} = result  # Fallback returns valid result
  end
end
```

### 10.2 Service Tests

```elixir
defmodule MealPlannerApi.Planning.PlanningServiceTest do
  use ExUnit.Case

  alias MealPlannerApi.Planning.PlanningService
  alias MealPlannerApi.Optimization.OptimizerMock

  defmodule FakeRecipeRepo do
    def list_for_slot(_account_id, :breakfast) do
      [%Recipe{id: "r1", name: "Oatmeal", calories_per_serving: 300}]
    end
    def list_for_slot(_account_id, :lunch) do
      [%Recipe{id: "r2", name: "Salad", calories_per_serving: 400}]
    end
    def list_for_slot(_account_id, :dinner) do
      [%Recipe{id: "r3", name: "Chicken", calories_per_serving: 500}]
    end
  end

  test "build_weekly_plan returns valid plan" do
    service = PlanningService.new(
      optimizer: OptimizerMock,
      recipe_repo: FakeRecipeRepo,
      planning_repo: FakePlanningRepo
    )

    user = %{account_id: "acc1", user_id: "u1", account_type: :individual, subscription_tier: :free}
    params = %{"days" => 7, "kcal_target" => 2100}

    {:ok, plan} = PlanningService.build_weekly_plan(service, user, params)
    
    assert length(plan.days) == 7
    assert plan.budget_within_limit == true
  end
end
```

### 10.3 Controller Tests

```elixir
defmodule MealPlannerApiWeb.PlanningControllerTest do
  use MealPlannerApiWeb.ConnCase

  alias MealPlannerApi.Auth.Guardian

  setup %{conn: conn} do
    {:ok, token, _} = Guardian.encode_and_sign(%{
      "sub" => "user1",
      "account_id" => "acc1",
      "account_type" => "individual",
      "subscription_tier" => "free"
    })

    %{conn: put_req_header(conn, "authorization", "Bearer #{token}")}
  end

  test "POST /api/planning/build", %{conn: conn} do
    conn = post(conn, "/api/planning/build", %{
      "planning" => %{"days" => 7, "kcal_target" => 2100}
    })

    assert %{
      "account_type" => "individual",
      "days" => days
    } = json_response(conn, 200)
    
    assert length(days) == 7
  end
end
```

---

## 11. Migration Checklist

### Phase 1: Ports (Day 1)
- [ ] Create `OptimizerPort` behaviour
- [ ] Create `OptimizerServer` GenServer
- [ ] Create `OptimizerFallback` 
- [ ] Create `OptimizerMock`
- [ ] Create `AIPort` behaviour
- [ ] Create `GeminiAdapter`
- [ ] Create `AIMock`
- [ ] Create `VoiceParserPort` behaviour
- [ ] Create `RuleBasedVoiceParser`
- [ ] Create `AIVoiceParser`
- [ ] Test ports in isolation

### Phase 2: Repos (Day 2)
- [ ] Create `RecipeRepo`
- [ ] Create `InventoryRepo`
- [ ] Create `AccountRepo`
- [ ] Create `PlanningRepo`
- [ ] Migrate existing queries from persistence modules
- [ ] Test repos with existing DB data

### Phase 3: Services (Day 3)
- [ ] Create `PlanningService`
- [ ] Create `InventoryService`
- [ ] Create `RecipeService`
- [ ] Create `AccountService`
- [ ] Create `SubscriptionService`
- [ ] Test services with mocks

### Phase 4: Controllers (Day 4)
- [ ] Update `PlanningController`
- [ ] Update `InventoryController`
- [ ] Update `AccountsController`
- [ ] Update `AuthController`
- [ ] Update `FallbackController` (RFC 7807)
- [ ] Test controllers

### Phase 5: Cleanup (Day 5)
- [ ] Delete old modules
- [ ] Run full test suite
- [ ] Verify API contracts
- [ ] Update documentation

---

*Design created: 2026-06-01*
*Status: pending tasks*