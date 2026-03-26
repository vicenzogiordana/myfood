defmodule MealPlannerApi.Planning.PythonOptimizerClient do
  @moduledoc """
  Python bridge for OR-Tools optimization.

  Expects the Python script to return JSON on stdout, either as the full output
  or in the last JSON-formatted line.
  """

  @behaviour MealPlannerApi.Planning.OptimizerClient
  @default_timeout_ms 10_000

  @impl true
  def select_weekly_menu(payload) when is_map(payload) do
    python_executable = System.get_env("MEAL_PLANNER_OPTIMIZER_PYTHON") || "python3"
    script_path = script_path()

    timeout_ms =
      Application.get_env(:meal_planner_api, :optimizer_timeout_ms, @default_timeout_ms)

    with {:ok, encoded_payload} <- Jason.encode(payload),
         {:ok, output} <-
           run_optimizer(python_executable, script_path, encoded_payload, timeout_ms),
         {:ok, decoded} <- decode_optimizer_output(output) do
      parse_optimizer_response(decoded)
    else
      {:error, _} = error -> error
    end
  end

  defp run_optimizer(python_executable, script_path, encoded_payload, timeout_ms) do
    try do
      {output, status} =
        System.cmd(python_executable, [script_path],
          input: encoded_payload,
          stderr_to_stdout: true,
          timeout: timeout_ms
        )

      if status == 0 do
        {:ok, output}
      else
        {:error, {:optimizer_failed, status, output}}
      end
    rescue
      error -> {:error, {:optimizer_unavailable, error}}
    catch
      :exit, {:timeout, _} -> {:error, :optimizer_timeout}
      :exit, reason -> {:error, {:optimizer_crash, reason}}
    end
  end

  defp script_path do
    configured = Application.get_env(:meal_planner_api, :optimizer_script_path)

    case configured do
      nil -> Path.expand("../optimizador.py", File.cwd!())
      value when is_binary(value) -> Path.expand(value)
    end
  end

  defp decode_optimizer_output(output) when is_binary(output) do
    trimmed = String.trim(output)

    case Jason.decode(trimmed) do
      {:ok, decoded} ->
        {:ok, decoded}

      {:error, _} ->
        decode_last_json_line(trimmed)
    end
  end

  defp decode_last_json_line(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reverse()
    |> Enum.find_value({:error, {:invalid_optimizer_output, output}}, fn line ->
      case Jason.decode(line) do
        {:ok, decoded} -> {:ok, decoded}
        {:error, _} -> false
      end
    end)
  end

  defp parse_optimizer_response(%{"error" => reason} = decoded) do
    {:error, {:optimizer_error, reason, decoded}}
  end

  defp parse_optimizer_response(%{"meals" => meals} = decoded) when is_list(meals) do
    {:ok, decoded}
  end

  defp parse_optimizer_response(decoded), do: {:error, {:invalid_optimizer_response, decoded}}
end
