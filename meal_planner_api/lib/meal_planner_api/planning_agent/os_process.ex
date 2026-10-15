defmodule MealPlannerApi.PlanningAgent.OsProcess do
  @moduledoc """
  Force-kills an OS process and waits until it is gone (spec #93: a running
  optimizer is really halted on Stop and Cancel).

  Closing a port only closes the child's stdin, which a busy solver never
  reads, so halting it takes `SIGKILL`. `kill/2` returns only once the
  process no longer exists, or reports `{:error, :still_alive}` after the
  timeout.
  """

  @poll_ms 10
  @default_timeout_ms 4_000

  @doc "Sends `SIGKILL` to `os_pid` and waits up to `timeout_ms` for it to be gone."
  @spec kill(non_neg_integer() | nil, non_neg_integer()) :: :ok | {:error, :still_alive}
  def kill(os_pid, timeout_ms \\ @default_timeout_ms)

  def kill(nil, _timeout_ms), do: :ok

  def kill(os_pid, timeout_ms) when is_integer(os_pid) and os_pid > 0 do
    _ = signal(os_pid, "-9")
    await_gone(os_pid, System.monotonic_time(:millisecond) + timeout_ms)
  end

  @doc "Whether `os_pid` still exists."
  @spec alive?(non_neg_integer()) :: boolean()
  def alive?(os_pid) when is_integer(os_pid) and os_pid > 0, do: signal(os_pid, "-0") == 0

  defp await_gone(os_pid, deadline) do
    cond do
      not alive?(os_pid) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, :still_alive}

      true ->
        # A killed child stays visible until the port's child reaper collects
        # it, which takes milliseconds.
        Process.sleep(@poll_ms)
        await_gone(os_pid, deadline)
    end
  end

  defp signal(os_pid, signal) do
    {_output, status} =
      System.cmd("kill", [signal, Integer.to_string(os_pid)], stderr_to_stdout: true)

    status
  rescue
    _ -> 1
  end
end
