defmodule CodexPoolerWeb.Admin.UpstreamAccountsReadModel.CreditProjectionTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Upstreams.Quota.{AccountQuotaWindow, CreditBalanceStore, WindowSelector}
  alias CodexPoolerWeb.Admin.UpstreamAccountsReadModel.QuotaProjection
  alias CodexPoolerWeb.DateTimeDisplay

  @now ~U[2026-09-01 12:00:00Z]

  test "account credits accompany API percentage without falling back to event quota" do
    usage = window("codex_usage_api", 29, DateTime.add(@now, -6), 0)
    event = window("codex_rate_limit_event", 30, @now, nil)
    assert [^usage] = WindowSelector.logical_windows([usage, event], @now)

    metadata =
      CreditBalanceStore.transition(%{}, %{"credits" => %{"balance" => 0}}, usage.observed_at, 2)

    credit = CreditBalanceStore.current(metadata, 2, @now)

    for windows <- [[usage], [event], [event, usage]] do
      rows =
        QuotaProjection.quota_limit_rows(
          windows,
          DateTimeDisplay.preferences_for_user(nil),
          @now,
          credit
        )

      weekly = Enum.find(rows, &(&1.key == :weekly))
      assert weekly.count_label == if(windows == [event], do: nil, else: "0 credits")
      assert weekly.percent_label == if(windows == [event], do: "not reported", else: "71%")
    end
  end

  test "untrusted credit snapshots do not fall back to balance on selected quota rows" do
    for freshness <- ["fresh", "unknown", "stale"] do
      window = %{window("codex_usage_api", 100, @now, 50) | freshness_state: freshness}

      rows =
        QuotaProjection.quota_limit_rows(
          [window],
          DateTimeDisplay.preferences_for_user(nil),
          @now,
          nil
        )

      weekly = Enum.find(rows, &(&1.key == :weekly))
      assert is_nil(weekly.count_label)
      assert is_nil(weekly.count_title)
      refute weekly.burning_credits
    end
  end

  test "credit burn stripe follows exhausted included quota independently of credit meter percentage" do
    usage = %{window("codex_usage_api", 100, @now, 500) | active_limit: 600}

    rows =
      QuotaProjection.quota_limit_rows(
        [usage],
        DateTimeDisplay.preferences_for_user(nil),
        @now,
        %{balance: 500}
      )

    weekly = Enum.find(rows, &(&1.key == :weekly))
    assert weekly.count_label == "500 credits"
    assert weekly.percent_label == "83%"
    assert weekly.burning_credits
  end

  defp window(source, used, observed_at, credits) do
    %AccountQuotaWindow{
      quota_key: "account",
      quota_scope: "account",
      quota_family: "account",
      source: source,
      source_precision: "observed",
      window_kind: "secondary",
      window_minutes: 10_080,
      used_percent: Decimal.new(used),
      credits: credits,
      observed_at: observed_at,
      last_sync_at: observed_at,
      freshness_state: "fresh",
      reset_at: DateTime.add(@now, 86_400),
      merge_precedence: 60
    }
  end
end
