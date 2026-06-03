ExUnit.start()

# :manual — cada test hace checkout explícito (requiere `use Phoenix.ChannelTest`
# con sandbox heredado, o `Ecto.Adapters.SQL.Sandbox.allow`). Usado en tests puros.
# :auto — cada test recibe conexión automáticamente. Requerido para
# controller tests que llaman Repo sin hacer checkout explícito.
Ecto.Adapters.SQL.Sandbox.mode(MealPlannerApi.Repo, :auto)
