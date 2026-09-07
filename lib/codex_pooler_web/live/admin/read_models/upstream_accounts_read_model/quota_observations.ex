defmodule CodexPoolerWeb.Admin.UpstreamAccountsReadModel.QuotaObservations do
  @moduledoc "Optional raw diagnostics beside the authoritative Usage API quota view."

  alias CodexPooler.Quotas.Evidence
  alias CodexPooler.Quotas.SourceObservations

  defdelegate key(window), to: SourceObservations

  def attach(rows, raw_windows, as_of) do
    groups = SourceObservations.groups(raw_windows, as_of)

    Enum.map(rows, &attach_row(&1, groups, as_of))
  end

  defp attach_row(row, groups, as_of) do
    windows = Map.get(groups, Map.get(row, :evidence_key), [])
    disagreement? = SourceObservations.disagreement?(windows, as_of, :usage)
    reset_disagreement? = SourceObservations.disagreement?(windows, as_of, :reset)

    row
    |> Map.put(:observations, observations(windows, as_of))
    |> Map.put(:source_disagreement, disagreement?)
    |> Map.put(:reset_disagreement, reset_disagreement?)
    |> Map.put(:selected_percent_label, row.percent_label)
    |> Map.update!(:label, &scope_label(row.key, &1))
  end

  defp scope_label(:weekly, label), do: "Account #{label}"

  defp scope_label(_key, label), do: label

  defp observations(windows, as_of) do
    windows
    |> Enum.sort_by(&{&1.source || "", iso8601(&1.observed_at), iso8601(&1.reset_at)})
    |> Enum.map(fn window ->
      %{
        source: window.source || "source not reported",
        observed_at: iso8601(window.observed_at),
        reset_at: iso8601(window.reset_at),
        freshness: Evidence.current_freshness_state(window, as_of),
        elapsed: Evidence.expired?(window, as_of),
        used: percent(window.used_percent),
        remaining: remaining(window.used_percent),
        descriptor: descriptor(window)
      }
    end)
  end

  defp descriptor(window) do
    [
      window.model,
      window.upstream_model,
      Map.get(window.metadata || %{}, "normal_model_slug")
    ]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
    |> Enum.join(" · ")
  end

  defp percent(%Decimal{} = value), do: "#{Decimal.to_string(value, :normal)}%"
  defp percent(_value), do: "not reported"
  defp remaining(%Decimal{} = used), do: percent(Decimal.sub(100, used))
  defp remaining(_used), do: "not reported"
  defp iso8601(%DateTime{} = time), do: DateTime.to_iso8601(time)
  defp iso8601(_time), do: "not reported"
end
