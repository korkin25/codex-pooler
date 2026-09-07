defmodule CodexPooler.Upstreams.Quota.Windows.Attributes do
  @moduledoc false

  alias CodexPooler.Upstreams.Quota

  @fresh "fresh"
  @account_quota_key "account"

  @spec from_metadata(term()) :: [map()]
  def from_metadata(%{} = metadata) do
    metadata
    |> Map.get("quota_windows", Map.get(metadata, :quota_windows, []))
    |> case do
      windows when is_list(windows) -> Enum.map(windows, &normalize/1)
      _value -> []
    end
  end

  def from_metadata(_metadata), do: []

  @spec from_windows([Quota.AccountQuotaWindow.t()]) :: [map()]
  def from_windows(windows) when is_list(windows) do
    Enum.map(windows, fn window ->
      %{
        quota_key: window.quota_key,
        window_kind: window.window_kind,
        window_minutes: window.window_minutes,
        active_limit: window.active_limit,
        credits: window.credits,
        reset_at: window.reset_at,
        used_percent: window.used_percent,
        display_label: window.display_label,
        limit_name: window.limit_name,
        metered_feature: window.metered_feature,
        source: window.source,
        source_precision: window.source_precision,
        quota_scope: window.quota_scope,
        quota_family: window.quota_family,
        model: window.model,
        upstream_model: window.upstream_model,
        raw_limit_id: window.raw_limit_id,
        raw_limit_name: window.raw_limit_name,
        raw_metered_feature: window.raw_metered_feature,
        freshness_state: window.freshness_state,
        last_sync_at: window.last_sync_at,
        observed_at: window.observed_at,
        merge_precedence: window.merge_precedence,
        metadata: window.metadata
      }
    end)
  end

  # Reason: quota window import accepts legacy atom and string key shapes.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  @spec normalize(map() | term()) :: map()
  def normalize(attrs) when is_map(attrs) do
    %{
      quota_key: attr(attrs, :quota_key) || @account_quota_key,
      window_kind: attr(attrs, :window_kind),
      window_minutes: attr(attrs, :window_minutes),
      active_limit: attr(attrs, :active_limit),
      credits: attr(attrs, :credits),
      reset_at: parse_optional_datetime(attr(attrs, :reset_at)),
      used_percent: decimal_or_nil(attr(attrs, :used_percent)),
      display_label: attr(attrs, :display_label),
      limit_name: attr(attrs, :limit_name),
      metered_feature: attr(attrs, :metered_feature),
      source: attr(attrs, :source) || "local_reconciliation",
      source_precision: attr(attrs, :source_precision),
      quota_scope: attr(attrs, :quota_scope),
      quota_family: attr(attrs, :quota_family),
      model: attr(attrs, :model),
      upstream_model: attr(attrs, :upstream_model),
      raw_limit_id: attr(attrs, :raw_limit_id),
      raw_limit_name: attr(attrs, :raw_limit_name),
      raw_metered_feature: attr(attrs, :raw_metered_feature),
      freshness_state: attr(attrs, :freshness_state) || @fresh,
      last_sync_at: parse_optional_datetime(attr(attrs, :last_sync_at)),
      observed_at: parse_optional_datetime(attr(attrs, :observed_at)),
      merge_precedence: attr(attrs, :merge_precedence),
      metadata: attr(attrs, :metadata) || %{}
    }
  end

  def normalize(_attrs), do: %{}

  defp attr(attrs, key) when is_atom(key) do
    Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
  end

  defp parse_optional_datetime(%DateTime{} = value), do: DateTime.truncate(value, :microsecond)
  defp parse_optional_datetime(nil), do: nil

  defp parse_optional_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.truncate(datetime, :microsecond)
      _invalid -> nil
    end
  end

  defp parse_optional_datetime(_value), do: nil

  defp decimal_or_nil(nil), do: nil
  defp decimal_or_nil(%Decimal{} = value), do: value
  defp decimal_or_nil(value) when is_integer(value), do: Decimal.new(value)
  defp decimal_or_nil(value) when is_float(value), do: Decimal.from_float(value)

  defp decimal_or_nil(value) when is_binary(value) do
    case Decimal.parse(String.trim(value)) do
      {%Decimal{} = decimal, ""} -> decimal
      _invalid -> nil
    end
  end

  defp decimal_or_nil(_value), do: nil
end
