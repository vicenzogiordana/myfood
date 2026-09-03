defmodule MealPlannerApiWeb.Channels.IntentAtomizer do
  @moduledoc """
  Converts a JSON-deserialized intent map (string keys, possibly
  nested) into the atom-keyed shape that
  `MealPlannerApi.Services.GenerationService.validate_ai_intent/1`
  and `PlanningSessionServer.apply_intent/3` expect.

  ## Contract

    * Keys are atomized **strictly**: an unknown key
      (`String.to_existing_atom/1` raises) returns `:error`.
      This is the security boundary — fabricated keys (e.g. a key
      the runtime has never seen) fail closed rather than silently
      passing through.
    * The `:kind` value is atomized **leniently**: an unknown
      string (e.g. `"totally_made_up"`) passes through unchanged so
      `validate_ai_intent/1` owns the `:unknown_intent` error path.
    * Map values recurse; lists recurse; everything else passes
      through.

  Returns `{:ok, atom_map}` or `:error` (no `{:error, reason}`
  shape — callers map `:error` to `:invalid_payload`).
  """

  @spec atomize(map()) :: {:ok, map()} | :error
  def atomize(%{} = intent), do: do_atomize(intent)
  def atomize(_), do: :error

  defp do_atomize(value) when is_map(value) do
    Enum.reduce_while(value, %{}, fn {k, v}, acc ->
      with {:ok, atom_key} <- safe_to_atom(k),
           {:ok, v_atom} <- atomize_value(atom_key, v) do
        {:cont, Map.put(acc, atom_key, v_atom)}
      else
        :error -> {:halt, :error}
      end
    end)
    |> case do
      %{} = m -> {:ok, m}
      :error -> :error
    end
  end

  defp do_atomize(value) when is_list(value) do
    Enum.reduce_while(value, [], fn item, acc ->
      case do_atomize(item) do
        {:ok, item_atom} -> {:cont, [item_atom | acc]}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      :error -> :error
      list -> {:ok, Enum.reverse(list)}
    end
  end

  defp do_atomize(value), do: {:ok, value}

  # For the `:kind` value: atomize known strings; pass unknown
  # strings through so the downstream validator returns its normal
  # `:unknown_intent` error.
  defp atomize_value(:kind, v) when is_binary(v) do
    case safe_to_atom(v) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:ok, v}
    end
  end

  defp atomize_value(_, v), do: do_atomize(v)

  defp safe_to_atom(k) when is_atom(k), do: {:ok, k}

  defp safe_to_atom(k) when is_binary(k) do
    {:ok, String.to_existing_atom(k)}
  rescue
    ArgumentError -> :error
  end

  defp safe_to_atom(_), do: :error
end
