defmodule CodexPooler.Quotas.Evidence.CodexParsers.ResetTimes do
  @moduledoc false

  @spec explicit_reset_at_from(map()) :: DateTime.t() | nil
  def explicit_reset_at_from(%{} = attrs) do
    attrs
    |> Map.drop(["reset_after_seconds", :reset_after_seconds])
    |> reset_at_from(nil)
  end

  @spec reset_source_precision(map(), DateTime.t() | nil) :: String.t()
  def reset_source_precision(_attrs, nil), do: "inferred"

  def reset_source_precision(%{} = attrs, %DateTime{}) do
    if explicit_reset_at_from(attrs), do: "observed", else: "inferred"
  end

  @spec reset_at_from(map(), DateTime.t() | nil) :: DateTime.t() | nil
  def reset_at_from(%{} = attrs, observed_at) do
    attrs
    |> reset_value()
    |> absolute_reset_at()
    |> Kernel.||(relative_reset_at(attrs, observed_at))
  end

  defp reset_value(attrs),
    do: attrs["reset_at"] || attrs["resets_at"] || attrs[:reset_at] || attrs[:resets_at]

  defp absolute_reset_at(%DateTime{} = reset), do: DateTime.truncate(reset, :microsecond)

  defp absolute_reset_at(reset) when is_integer(reset) and reset > 0 do
    reset
    |> DateTime.from_unix()
    |> case do
      {:ok, datetime} -> DateTime.truncate(datetime, :microsecond)
      _invalid -> nil
    end
  end

  defp absolute_reset_at(reset) when is_binary(reset) do
    reset
    |> String.trim()
    |> parse_reset_string()
  end

  defp absolute_reset_at(_reset), do: nil

  defp relative_reset_at(_attrs, nil), do: nil

  defp relative_reset_at(attrs, observed_at) do
    attrs
    |> reset_after_seconds()
    |> reset_after_datetime(observed_at)
  end

  defp reset_after_seconds(attrs),
    do: integer_or_nil(attrs["reset_after_seconds"] || attrs[:reset_after_seconds])

  defp reset_after_datetime(seconds, observed_at) when is_integer(seconds) and seconds >= 0 do
    case DateTime.from_unix(
           DateTime.to_unix(observed_at, :microsecond) + seconds * 1_000_000,
           :microsecond
         ) do
      {:ok, _datetime} -> DateTime.add(observed_at, seconds, :second)
      {:error, :invalid_unix_time} -> nil
    end
  end

  defp reset_after_datetime(_seconds, _observed_at), do: nil

  defp parse_reset_string(value) do
    case Integer.parse(value) do
      {unix_seconds, ""} when unix_seconds > 0 ->
        absolute_reset_at(unix_seconds)

      _not_unix ->
        datetime_or_nil(value)
    end
  end

  defp integer_or_nil(value) when is_integer(value), do: value
  defp integer_or_nil(value) when is_float(value) and value >= 0, do: trunc(value)

  defp integer_or_nil(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} -> integer
      _invalid -> nil
    end
  end

  defp integer_or_nil(_value), do: nil

  defp datetime_or_nil(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.truncate(datetime, :microsecond)
      _invalid -> nil
    end
  end
end
