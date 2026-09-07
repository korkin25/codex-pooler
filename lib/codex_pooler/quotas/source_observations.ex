defmodule CodexPooler.Quotas.SourceObservations do
  @moduledoc "Pure source grouping and disagreement semantics shared by UI and metrics."

  alias CodexPooler.Quotas.Evidence
  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Quota.WindowSelector

  # Presentation tolerance for timestamp rounding and collection delay. This
  # does not identify quota cycles or change source timestamps/routing policy.
  @reset_display_tolerance_seconds 60

  def key(%AccountQuotaWindow{window_kind: "primary", window_minutes: 10_080} = window),
    do: key(%{window | window_kind: "secondary"})

  def key(window) do
    {WindowSelector.logical_key(window), Evidence.additional_meter_token(window)}
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, "quota-observation-group-v1:" <> &1))
    |> Base.encode16(case: :lower)
  end

  def groups(raw_windows, as_of) do
    raw_windows
    |> Enum.reject(&future_observation?(&1, as_of))
    |> Enum.group_by(&key/1)
  end

  def disagreement?(windows, as_of, dimension) do
    current =
      Enum.filter(windows, fn window ->
        not Evidence.expired?(window, as_of) and match?(%Decimal{}, window.used_percent)
      end)

    current
    |> Enum.any?(fn left ->
      Enum.any?(current, fn right ->
        left.source != right.source and
          different_report?(left, right, dimension)
      end)
    end)
  end

  defp different_report?(left, right, :usage) do
    # Usage can grow between samples. A decrease before either reported window
    # ends is uncertain, even if the newer source reports a later reset.
    case observation_order(left.observed_at, right.observed_at) do
      :lt -> Decimal.compare(left.used_percent, right.used_percent) == :gt
      :gt -> Decimal.compare(right.used_percent, left.used_percent) == :gt
      _same_or_unknown -> not Decimal.equal?(left.used_percent, right.used_percent)
    end
  end

  defp different_report?(
         %{reset_at: %DateTime{} = left},
         %{reset_at: %DateTime{} = right},
         :reset
       ),
       do: abs(DateTime.diff(left, right, :second)) > @reset_display_tolerance_seconds

  defp different_report?(_left, _right, :reset), do: false

  defp observation_order(%DateTime{} = left, %DateTime{} = right),
    do: DateTime.compare(left, right)

  defp observation_order(_left, _right), do: :unknown

  defp future_observation?(%{observed_at: %DateTime{} = observed_at}, as_of),
    do: DateTime.compare(observed_at, as_of) == :gt

  defp future_observation?(_window, _as_of), do: false
end
