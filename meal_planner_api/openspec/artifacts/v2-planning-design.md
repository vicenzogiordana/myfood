# Design: v2 Planning Streaming + Recipe Pricing

## 1. Module Map

```
lib/meal_planner_api/
│
├── generation/
│   ├── generation_server.ex         ← OTP GenServer, one per account (Registry)
│   └── generation/supervisor.ex     ← DynamicSupervisor for GenerationServer instances
│       (no behaviour file — Channel calls GenServer directly)
│
├── integrations/
│   ├── python_client.ex              ← HTTP client → Python FastAPI (Tesla)
│   ├── python_client/mock.ex         ← Development mock (returns fake slot progress)
│   ├── go_scraper_client.ex          ← HTTP client → Go scraper API (Tesla)
│   └── go_scraper_client/mock.ex     ← Development mock
│
├── services/
│   ├── price_service.ex              ← Reads ingredient_prices, computes recipe_prices
│   └── generation_service.ex         ← Stateless orchestration (used by GenerationServer)
│
├── data/
│   ├── price_repo.ex                 ← ingredient_prices + recipe_prices queries
│   ├── user_preference_repo.ex       ← user_preferences CRUD
│   └── planning_repo.ex              ← existing (extends with proposal status updates)
│
└── persistence/
    ├── accounts/
    │   └── user_preference.ex         ← protein_g_per_meal, default_exclusions
    └── planning/
        └── proposal.ex                ← existing (extends with status: confirmed)

lib/meal_planner_api_web/
│
├── channels/
│   └── planning_channel.ex           ← Phoenix Channel — join + handle_in/3
│
└── controllers/
    └── price_sync_controller.ex       ← Manual trigger for price_sync (admin only)
```

**Mix task:**
```
lib/mix/tasks/price_sync.run.ex        ← mix price_sync.run
```

---

## 2. GenerationServer (OTP)

### 2.1 Registry-based naming

```elixir
# One server per account
key = {:generation, account_id}
{:via, Registry, {MealPlannerApi.Registry.Generations, key}}
```

Uses `DynamicSupervisor` to start/stop per-account servers.

### 2.2 State machine (via GenStateMachine or plain case)

```
:idle
  ├── start(constraints) → :running
  └── _ → {:error, :not_idle}

:running
  ├── slot_progress_received → stay (:running, updated proposal_json)
  ├── all_slots_done → :completed
  └── error_received → :error

:completed
  ├── chat(message) → :running (partial regeneration)
  ├── confirm → :idle (cleanup)
  └── reject → :idle (cleanup)

:error
  └── start → :running
```

### 2.3 Interface

```elixir
defmodule MealPlannerApi.Generation.Server do
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts)

  @spec start_generation(account_id, user_id, constraints :: map(), socket :: pid()) ::
          {:ok, run_id} | {:error, :already_running}
  def start_generation(account_id, user_id, constraints, socket)

  @spec chat(pid(), proposal_id :: String.t(), message :: String.t()) :: :ok
  def chat(server, proposal_id, message)

  @spec confirm(pid(), proposal_id :: String.t()) :: {:ok, map()} | {:error, term()}
  def confirm(server, proposal_id)

  @spec reject(pid(), proposal_id :: String.t()) :: :ok
  def reject(server, proposal_id)

  @spec get_status(account_id) :: GenerationServer.t()
  def get_status(account_id)
end
```

---

## 3. PlanningChannel

```elixir
defmodule MealPlannerApiWeb.PlanningChannel do
  use Phoenix.Channel

  intercept ["slot_progress", "proposal_ready", "proposal_update", "error", "confirmed"]

  def join("planning:lobby", _params, socket) do
    user = Guardian.Phoenix.Socket.current_resource(socket)
    send(self(), :after_join)
    {:ok, assign(socket, :user, user)}
  end

  def handle_info(:after_join, socket) do
    # Track presence if needed
    {:noreply, socket}
  end

  def handle_in("start", %{"constraints" => constraints}, socket) do
    user = socket.assigns.user

    case GenerationServer.start_generation(
           user.account_id,
           user.id,
           constraints,
           socket.channel_pid
         ) do
      {:ok, run_id} ->
        {:reply, {:ok, %{run_id: run_id}}, socket}

      {:error, :already_running} ->
        {:reply, {:error, %{reason: "generation_in_progress"}}, socket}
    end
  end

  def handle_in("chat", %{"message" => message, "proposal_id" => p_id}, socket) do
    :ok = GenerationServer.chat(socket.assigns.generation_pid, p_id, message)
    {:noreply, socket}
  end

  def handle_in("confirm", %{"proposal_id" => p_id}, socket) do
    case GenerationServer.confirm(socket.assigns.generation_pid, p_id) do
      {:ok, result} -> {:reply, {:ok, result}, socket}
      {:error, reason} -> {:reply, {:error, %{reason: reason}}, socket}
    end
  end

  def handle_in("reject", %{"proposal_id" => p_id}, socket) do
    :ok = GenerationServer.reject(socket.assigns.generation_pid, p_id)
    {:noreply, socket}
  end
end
```

**Broadcast helper** (used by GenerationServer via `send`):
```elixir
defp broadcast_to_channel(channel_pid, event, payload) do
  send(channel_pid, {:broadcast, event, payload})
end
```

---

## 4. HTTP Clients

### 4.1 PythonClient

```elixir
defmodule MealPlannerApi.Integrations.PythonClient do
  use Tesla

  @base_url Application.get_env(:meal_planner_api, :python_api_url)
  @timeout Application.get_env(:meal_planner_api, :optimize_timeout_ms, 30_000)

  def optimize_menu(slots, constraints) do
    post("/api/v1/optimize-menu", %{
      slots: slots,
      budget_cents: constraints.budget_cents,
      protein_g_per_meal: constraints.protein_g_per_meal,
      exclusions: constraints.exclusions || [],
      preferences: constraints.preferences || []
    })
  end

  def optimize_slot(slot, constraints) do
    post("/api/v1/optimize-slot", %{
      date: slot.date,
      slot: slot.slot,
      available_recipe_ids: slot.available_recipe_ids,
      constraints: constraints
    })
  end

  def extract_shopping_list(recipes) do
    post("/api/v1/extract-shopping-list", %{recipes: recipes})
  end

  adapter Tesla.Adapter.Hackney, timeout: @timeout
end
```

**Mock implementation** (`PythonClient.Mock`):
- `optimize_menu/2` returns a list of 35 mock slots, emitting progress events via `Process.send_after/3`
- `extract_shopping_list/1` returns a realistic shopping items list
- Used when `MIX_ENV=test` or `PYTHON_API_URL` is not set

### 4.2 GoScraperClient

```elixir
defmodule MealPlannerApi.Integrations.GoScraperClient do
  @base_url Application.get_env(:meal_planner_api, :go_scraper_url)

  def get_price(ingredient_name) do
    get("/price", query: [ingredient: ingredient_name])
  end
end
```

---

## 5. PriceService

```elixir
defmodule MealPlannerApi.Services.PriceService do
  alias MealPlannerApi.Data.PriceRepo

  @spec latest_prices_for_ingredients([pos_integer()]) :: %{ingredient_id => %{supermarket_id => cents}}
  def latest_prices_for_ingredients(ingredient_ids) do
    PriceRepo.latest_prices(ingredient_ids)
  end

  @spec compute_recipe_price(recipe_id) :: cents :: integer()
  def compute_recipe_price(recipe_id) do
    recipe = RecipeRepo.get_with_ingredients!(recipe_id)

    recipe.recipe_ingredients
    |> Enum.map(&lookup_price(&1))
    |> Enum.sum()
  end

  defp lookup_price(%{ingredient_id: id, quantity: qty, unit: unit}) do
    price = PriceRepo.latest_price(id)  # picks best supermarket
    floor(price.cents_per_unit * qty)
  end
end
```

---

## 6. PriceRepo

```elixir
defmodule MealPlannerApi.Data.PriceRepo do
  import Ecto.Query

  @spec latest_prices([pos_integer()]) :: %{pos_integer() => pos_integer()}
  def latest_prices(ingredient_ids) do
    from(ip in IngredientPrice,
      where: ip.ingredient_id in ^ingredient_ids,
      where: ip.scraped_at > ago(1, "day"),
      select: {ip.ingredient_id, ip.price_per_unit_cents}
    )
    |> Repo.all()
    |> Enum.into(%{})
  end

  @spec best_price_per_ingredient([pos_integer()]) :: %{pos_integer() => pos_integer()}
  def best_price_per_ingredient(ingredient_ids) do
    from(ip in IngredientPrice,
      where: ip.ingredient_id in ^ingredient_ids,
      where: ip.scraped_at > ago(1, "day"),
      group_by: ip.ingredient_id,
      select: {ip.ingredient_id, min(ip.price_per_unit_cents)}
    )
    |> Repo.all()
    |> Enum.into(%{})
  end
end
```

---

## 7. Mix Task — Price Sync

```bash
mix price_sync.run
```

```elixir
defmodule Mix.Tasks.PriceSync.Run do
  use Mix.Task

  def run(_args) do
    Mix.shell().info("Starting price sync...")
    # 1. List all ingredients
    # 2. For each: GoScraperClient.get_price(name)
    # 3. Upsert IngredientPrice
    # 4. Compute recipe_prices
    # 5. Log summary
  end
end
```

---

## 8. Migrations

```elixir
# 1. ingredient_prices
create table(:ingredient_prices, primary_key: false) do
  add :id, :binary_id, primary_key: true
  add :ingredient_id, references(:ingredients, type: :binary_id), null: false
  add :supermarket_id, :string, null: false
  add :price_per_unit_cents, :integer, null: false
  add :unit, :string, null: false
  add :scraped_at, :utc_datetime, null: false
  timestamps()
end
create unique_index(:ingredient_prices, [:ingredient_id, :supermarket_id])

# 2. recipe_prices
create table(:recipe_prices, primary_key: false) do
  add :id, :binary_id, primary_key: true
  add :recipe_id, references(:recipes, type: :binary_id), null: false, unique: true
  add :price_per_serving_cents, :integer, null: false
  add :last_calculated_at, :utc_datetime, null: false
  timestamps()
end

# 3. user_preferences (if not exists)
create table(:user_preferences, primary_key: false) do
  add :id, :binary_id, primary_key: true
  add :user_id, references(:users, type: :binary_id), null: false, unique: true
  add :protein_g_per_meal, :integer
  add :default_exclusions, {:array, :string}
  timestamps()
end
```

---

## 9. New Dependencies

```elixir
# mix.exs
# Tesla already in deps — used for PythonClient and GoScraperClient
{:gen_state_machine, "~> 3.0"},  # Optional: for GenerationServer state machine
{:jason, "~> 1.4"}         # JSON (already in deps)
```

---

## 10. Directory Structure (new files)

```
lib/meal_planner_api/
├── generation/
│   ├── __init__.ex
│   ├── generation_server.ex
│   └── supervisor.ex
├── integrations/
│   ├── __init__.ex
│   ├── python_client.ex
│   ├── python_client/
│   │   ├── __init__.ex
│   │   └── mock.ex
│   ├── go_scraper_client.ex
│   └── go_scraper_client/
│       ├── __init__.ex
│       └── mock.ex
├── services/
│   └── price_service.ex
└── data/
    ├── price_repo.ex
    └── user_preference_repo.ex

lib/mix/tasks/
└── price_sync.run.ex

priv/repo/migrations/
├── 20250603000000_create_ingredient_prices.exs
├── 20250603000001_create_recipe_prices.exs
└── 20250603000002_create_user_preferences.exs

test/meal_planner_api/
├── generation/
│   └── generation_server_test.exs
├── integrations/
│   ├── python_client_test.exs
│   └── go_scraper_client_test.exs
├── services/
│   └── price_service_test.exs
└── data/
    └── price_repo_test.exs

test/meal_planner_api_web/channels/
└── planning_channel_test.exs
```