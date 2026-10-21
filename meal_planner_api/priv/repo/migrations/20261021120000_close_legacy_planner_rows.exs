defmodule MealPlannerApi.Repo.Migrations.CloseLegacyPlannerRows do
  @moduledoc """
  Closes the rows the legacy planner left open (issue #151). The legacy
  planner was switched off in issue #110 and nothing reads
  `planning_generation_runs` or `planning_proposals` any more, so a run still
  `pending` or `processing`, or a proposal still `pending`, would stay so
  forever. They become terminal once: runs `error`, proposals `rejected`.

  The tables and their rows stay as a historical record; dropping them is a
  separate decision. `down/0` does nothing: which rows were open is not kept.
  """

  use Ecto.Migration

  @doc "The cleanup statements, also run by the test of this migration."
  def statements do
    [
      """
      UPDATE planning_generation_runs
      SET status = 'error', completed_at = COALESCE(completed_at, now()), updated_at = now()
      WHERE status IN ('pending', 'processing')
      """,
      """
      UPDATE planning_proposals
      SET status = 'rejected', updated_at = now()
      WHERE status = 'pending'
      """
    ]
  end

  def up, do: Enum.each(statements(), &execute/1)

  def down, do: :ok
end
