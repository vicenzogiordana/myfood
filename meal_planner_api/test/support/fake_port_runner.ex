defmodule MealPlannerApi.Optimization.TestSupport.FakePortRunner do
  @moduledoc """
  Test-only port runner.

  Opens a local inert process (default `sleep`) so that the GenServer's port
  lifecycle can be exercised without spawning Python. Tests inject frames
  directly via `send(genserver_pid, {port, {:data, ...}})`; the child must not
  echo outbound handshake or solve frames back as inbound data.

  The returned port is also stashed in `:persistent_term` so that tests can
  retrieve the exact reference (`get_port/0`) and write frames if they want
  to exercise the subprocess echo path.
  """

  @table :fake_port_runner

  @spec open_port(keyword()) :: {:ok, port()} | {:error, :spawn_failed}
  def open_port(opts \\ []) do
    executable = Keyword.get(opts, :executable, System.find_executable("sleep"))

    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        args: ["60"]
      ])

    case Port.info(port, :name) do
      {:name, name} when is_list(name) and name != [] ->
        :persistent_term.put(@table, port)
        {:ok, port}

      _ ->
        {:error, :spawn_failed}
    end
  end

  @spec get_port() :: port() | nil
  def get_port, do: :persistent_term.get(@table, nil)

  @spec clear_port() :: :ok
  def clear_port do
    case :persistent_term.get(@table, nil) do
      nil ->
        :ok

      port ->
        if is_port(port) do
          try do
            Port.close(port)
          catch
            _kind, _value -> :ok
          end
        end

        _ = :persistent_term.erase(@table)
        :ok
    end
  end
end
