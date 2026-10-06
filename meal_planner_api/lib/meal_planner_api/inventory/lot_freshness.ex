defmodule MealPlannerApi.Inventory.LotFreshness do
  @moduledoc """
  Pure freshness and FEFO rules shared by inventory readers and consumers.

  An explicit expiry always wins. Otherwise expiry is inferred from the acquisition
  date and ingredient category. Lots without an acquisition date retain the inventory
  view's existing behavior by using the operation's captured reference date.
  """

  @fallback_shelf_life_days 14

  @spec effective_expiry(map(), Date.t() | DateTime.t()) :: Date.t()
  def effective_expiry(item, reference) do
    date_value(Map.get(item, :expired_at)) || inferred_expiry(item, reference)
  end

  @spec inferred_expiry(map(), Date.t() | DateTime.t()) :: Date.t()
  def inferred_expiry(item, reference) do
    acquired_on = date_value(Map.get(item, :acquired_at)) || reference_date(reference)
    Date.add(acquired_on, shelf_life_days(item))
  end

  @spec usable?(map(), Date.t() | DateTime.t()) :: boolean()
  def usable?(item, reference) do
    Date.compare(effective_expiry(item, reference), reference_date(reference)) != :lt
  end

  @spec status(map(), Date.t() | DateTime.t(), non_neg_integer()) :: String.t()
  def status(item, reference, warning_days) do
    days_until = Date.diff(effective_expiry(item, reference), reference_date(reference))

    cond do
      days_until < 0 -> "expired"
      days_until <= warning_days -> "warning"
      true -> "ok"
    end
  end

  @spec fefo_sort_key(map(), Date.t() | DateTime.t()) :: tuple()
  def fefo_sort_key(item, reference) do
    {
      Date.to_gregorian_days(effective_expiry(item, reference)),
      nullable_datetime_key(Map.get(item, :acquired_at)),
      nullable_datetime_key(Map.get(item, :inserted_at)),
      Map.get(item, :id) || ""
    }
  end

  defp shelf_life_days(item) do
    category =
      case Map.get(item, :ingredient) do
        nil -> nil
        ingredient -> Map.get(ingredient, :category)
      end

    case category do
      :produce -> 5
      :dairy -> 7
      :meat -> 3
      _ -> @fallback_shelf_life_days
    end
  end

  defp nullable_datetime_key(nil), do: {1, 0}

  defp nullable_datetime_key(%DateTime{} = datetime) do
    {0, DateTime.to_unix(datetime, :microsecond)}
  end

  defp nullable_datetime_key(%Date{} = date), do: {0, Date.to_gregorian_days(date)}

  defp date_value(nil), do: nil
  defp date_value(%DateTime{} = datetime), do: DateTime.to_date(datetime)
  defp date_value(%Date{} = date), do: date

  defp reference_date(%DateTime{} = datetime), do: DateTime.to_date(datetime)
  defp reference_date(%Date{} = date), do: date
end
