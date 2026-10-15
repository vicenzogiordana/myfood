defmodule MealPlannerApi.PlanningAgent.FlakyConfirmationStore do
  @moduledoc """
  Hand-written confirmation store fake for planning agent tests, over the
  real store (`MealPlannerApi.PlanningAgent.Confirmation`).

  Option `:mode`:

    * `:lost_ack` — the commit really saves, then its acknowledgement is
      lost (the call raises a connection error)
    * `:unreachable` — every commit and status call raises a connection
      error, so nothing can be verified

  `:notify` receives `{:confirmation_store, call}` for every call.
  """

  alias MealPlannerApi.PlanningAgent.Confirmation

  def commit(attrs, opts) do
    notify(opts, :commit)

    case Keyword.fetch!(opts, :mode) do
      :lost_ack ->
        {:ok, _summary} = Confirmation.commit(attrs)
        lost!()

      :unreachable ->
        lost!()
    end
  end

  def status(account_id, confirmation_id, opts) do
    notify(opts, :status)

    case Keyword.fetch!(opts, :mode) do
      :lost_ack -> Confirmation.status(account_id, confirmation_id)
      :unreachable -> lost!()
    end
  end

  defp lost!, do: raise(DBConnection.ConnectionError, "fictitious lost connection")

  defp notify(opts, call) do
    if pid = Keyword.get(opts, :notify), do: send(pid, {:confirmation_store, call})
  end
end
