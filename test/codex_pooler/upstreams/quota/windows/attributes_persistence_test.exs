defmodule CodexPooler.Upstreams.Quota.Windows.AttributesPersistenceTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Quota.Windows

  @observed_at ~U[2026-09-01 10:00:00.123456Z]
  @reset_at ~U[2026-09-01 12:00:00.123456Z]

  test "legacy string-key quota metadata survives real persistence and attribute export" do
    %{identity: identity} = active_upstream_assignment_fixture(pool_fixture(), %{})

    attrs =
      window_attrs()
      |> Map.merge(%{
        "used_percent" => " 12.50 ",
        "active_limit" => 0,
        "credits" => 0,
        "display_label" => "Account quota",
        "raw_limit_id" => "sample_limit",
        "metadata" => %{"reset_state" => "anchored"}
      })

    normalized = Windows.quota_windows_from_metadata(%{"quota_windows" => [attrs]})
    assert {:ok, [window]} = Windows.upsert_quota_windows(identity, normalized)
    persisted = Repo.get!(AccountQuotaWindow, window.id)

    assert persisted.reset_at == @reset_at
    assert persisted.last_sync_at == @observed_at
    assert persisted.observed_at == @observed_at
    assert Decimal.equal?(persisted.used_percent, Decimal.new("12.5"))
    assert persisted.active_limit == 0
    assert persisted.credits == 0
    assert persisted.raw_limit_id == "sample_limit"
    assert persisted.metadata["reset_state"] == "anchored"

    assert [exported] = Windows.existing_quota_window_attrs(identity)

    assert %{
             quota_key: "account",
             window_kind: "primary",
             window_minutes: 300,
             source: "codex_usage_api",
             source_precision: "authoritative",
             quota_scope: "account",
             quota_family: "account",
             display_label: "Account quota",
             raw_limit_id: "sample_limit",
             reset_at: @reset_at,
             last_sync_at: @observed_at,
             observed_at: @observed_at,
             active_limit: 0,
             credits: 0,
             freshness_state: "fresh"
           } = exported

    assert exported == Map.take(Map.from_struct(persisted), Map.keys(exported))
    assert {:ok, [rewritten]} = Windows.upsert_quota_windows(identity, [exported])
    assert rewritten.id == persisted.id
    assert Repo.aggregate(AccountQuotaWindow, :count) == 1
  end

  test "malformed legacy percentages remain absent and preserve an explicit zero limit" do
    %{identity: identity} = active_upstream_assignment_fixture(pool_fixture(), %{})

    for value <- [true, false, %{}, [], "unknown"] do
      normalized =
        Windows.quota_windows_from_metadata(%{
          "quota_windows" => [
            Map.merge(window_attrs(), %{"used_percent" => value, "active_limit" => 0})
          ]
        })

      assert {:ok, [window]} = Windows.upsert_quota_windows(identity, normalized)
      assert Repo.get!(AccountQuotaWindow, window.id).used_percent == nil
      refute Windows.routing_quota_eligibility(identity, at: @observed_at).eligible?
    end
  end

  test "direct upsert accepts malformed optional percentages like legacy metadata" do
    %{identity: identity} = active_upstream_assignment_fixture(pool_fixture(), %{})

    assert {:ok, [window]} =
             Windows.upsert_quota_windows(identity, [Map.put(window_attrs(), "used_percent", %{})])

    assert Repo.get!(AccountQuotaWindow, window.id).used_percent == nil
  end

  defp window_attrs do
    %{
      "window_kind" => "primary",
      "window_minutes" => 300,
      "source" => "codex_usage_api",
      "source_precision" => "authoritative",
      "quota_scope" => "account",
      "quota_family" => "account",
      "reset_at" => "2026-09-01T14:00:00.123456+02:00",
      "last_sync_at" => @observed_at,
      "observed_at" => DateTime.to_iso8601(@observed_at)
    }
  end
end
