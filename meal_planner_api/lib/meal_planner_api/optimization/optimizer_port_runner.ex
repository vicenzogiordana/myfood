defmodule MealPlannerApi.Optimization.OptimizerPortRunner do
  @moduledoc """
  Spawns the Python optimizer subprocess via Port.

  Production uses `{:spawn_executable, python}` + `args: [script_path]`,
  which avoids shell interpolation entirely. Tests inject a custom runner
  through `:meal_planner_api, :optimizer_port_runner` to drive the GenServer
  lifecycle without spawning a real Python process.
  """

  @doc """
  Opens a Port to the configured Python executable running `optimizador.py`.

  ## Options

    * `:python_executable` — overrides `:optimizer_python` app config
    * `:script_path` — overrides `:optimizer_script_path` app config

  Returns `{:ok, port}` on success, or `{:error, :spawn_failed}` if Erlang
  could not start the subprocess.
  """
  @spec open_port(keyword()) :: {:ok, port()} | {:error, :spawn_failed}
  def open_port(opts \\ []) do
    python_executable = Keyword.get(opts, :python_executable, default_python())
    script_path = Keyword.get(opts, :script_path, default_script_path())

    port =
      Port.open(
        {:spawn_executable, python_executable},
        [
          :binary,
          :exit_status,
          :use_stdio,
          :stderr_to_stdout,
          args: [script_path]
        ]
      )

    case Port.info(port, :name) do
      {:name, name} when is_list(name) and name != [] -> {:ok, port}
      _ -> {:error, :spawn_failed}
    end
  end

  @doc """
  Returns the configured Python executable (defaults to `"python3"`).
  """
  @spec default_python() :: String.t()
  def default_python do
    Application.get_env(:meal_planner_api, :optimizer_python, "python3")
  end

  @doc """
  Returns the absolute path to `optimizador.py`, defaulting to the repo root.
  """
  @spec default_script_path() :: String.t()
  def default_script_path do
    Application.get_env(
      :meal_planner_api,
      :optimizer_script_path,
      Path.expand("../../../../optimizador.py", __DIR__)
    )
  end
end
