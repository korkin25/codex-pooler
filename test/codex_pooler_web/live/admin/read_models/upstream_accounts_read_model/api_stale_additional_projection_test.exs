defmodule CodexPoolerWeb.Admin.UpstreamAccountsReadModel.ApiStaleAdditionalProjectionTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias CodexPooler.Quotas.Evidence
  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPoolerWeb.Admin.UpstreamAccountsReadModel.QuotaProjection
  alias CodexPoolerWeb.Admin.UpstreamPageComponents.AccountCard.QuotaLimitRow
  alias CodexPoolerWeb.DateTimeDisplay

  @now ~U[2026-09-07 12:00:00Z]

  test "a newer header cannot turn a stale API meter into current capacity" do
    old_at = DateTime.add(@now, -(Evidence.freshness_ttl_seconds() + 1))
    api = window(98, old_at)
    header = %{window(0, @now) | source: "codex_response_headers"}

    for raw <- [[api, header], [header, api]] do
      assert [row] = additional_rows(raw)
      assert row.selected_source == "codex_usage_api"
      assert row.percent_label == "2%"
      assert row.meter_state == :historical
      assert row.evidence_state == :stale
      assert row.freshness_label == "last reported"
      assert row.observed_title =~ Date.to_iso8601(DateTime.to_date(old_at))
      assert row.reset_display_state == :unconfirmed
      html = render_component(&QuotaLimitRow.quota_limit_row/1, id: "stale-spark", limit: row)
      assert html =~ "last reported"
      assert html =~ "2%"
      refute html =~ "Sources disagree"
      refute html =~ "Reset reports differ"
    end
  end

  test "unsupported or unmeasured API meters do not acquire a header percentage" do
    header = %{window(0, @now) | source: "codex_response_headers"}
    assert additional_rows([header]) == []
    assert additional_rows([%{window(0, @now) | used_percent: nil}, header]) == []
  end

  test "a fresh API correction restores the same meter without historical freshness" do
    old_at = DateTime.add(@now, -(Evidence.freshness_ttl_seconds() + 1))
    old = window(100, old_at)
    fresh = window(0, @now)
    assert [previous] = additional_rows([old])
    assert previous.meter_state == :historical_exhausted
    assert [current] = additional_rows([old, fresh])
    assert current.key == previous.key
    assert current.percent_label == "100%"
    assert current.evidence_state == :fresh
    assert current.meter_state == :current
    assert current.reset_at == fresh.reset_at
    assert current.reset_display_state == :countdown
  end

  defp additional_rows(raw) do
    raw
    |> QuotaProjection.quota_limit_rows(DateTimeDisplay.preferences_for_user(nil), @now, nil, raw)
    |> Enum.reject(&is_atom(&1.key))
  end

  defp window(used, observed_at) do
    %AccountQuotaWindow{
      quota_key: "codex_spark",
      quota_scope: "model",
      quota_family: "codex_spark",
      model: "gpt-5.3-codex-spark",
      window_kind: "primary",
      window_minutes: 300,
      used_percent: Decimal.new(used),
      source: "codex_usage_api",
      source_precision: "authoritative",
      freshness_state: "fresh",
      observed_at: observed_at,
      last_sync_at: observed_at,
      reset_at: DateTime.add(observed_at, 18_000),
      metadata: %{}
    }
  end
end
