defmodule CodexPooler.Upstreams.Quota.Windows.ModelPrimaryTimerTest do
  use CodexPooler.DataCase, async: false
  import CodexPooler.PoolerFixtures
  alias CodexPooler.Quotas.Evidence.CodexParsers
  alias CodexPooler.Upstreams.Quota.Windows.EvidenceStore
  alias CodexPoolerWeb.Admin.UpstreamAccountsReadModel.QuotaProjection

  @start ~U[2026-08-01 09:00:00.000000Z]

  test "provider sliding model primary displays each API reset and fences older replays" do
    %{identity: identity} = active_upstream_assignment_fixture(pool_fixture(), %{})
    assert {:ok, _} = persist(identity, @start, @start)
    t1 = DateTime.add(@start, 60)
    assert {:ok, _} = persist(identity, t1, t1)
    t2 = DateTime.add(@start, 240)
    assert {:ok, reported} = persist(identity, t2, t2)
    assert reported.reset_at == DateTime.add(t2, 18_000)
    refute reported.metadata["reset_state"] == "floating"

    assert Enum.any?(
             QuotaProjection.quota_limit_rows([reported], %{}, t2),
             &(&1.reset_display_state == :countdown and &1.reset_at == reported.reset_at)
           )

    t3 = DateTime.add(t2, 90)
    assert {:ok, anchored} = persist(identity, t3, t2)
    assert anchored.reset_at == reported.reset_at
    refute anchored.metadata["reset_state"] == "floating"

    assert Enum.any?(
             QuotaProjection.quota_limit_rows([anchored], %{}, t3),
             &(&1.reset_display_state == :countdown and &1.reset_at == anchored.reset_at)
           )

    assert {:ok, replayed} = persist(identity, t1, t1)
    assert replayed.reset_at == anchored.reset_at
    assert replayed.observed_at == anchored.observed_at
    assert replayed.metadata == anchored.metadata
  end

  test "a distant provider model primary reset correction is authoritative immediately" do
    %{identity: identity} = active_upstream_assignment_fixture(pool_fixture(), %{})
    assert {:ok, original} = persist(identity, @start, @start)
    t1 = DateTime.add(@start, 7200)
    cycle = DateTime.add(t1, -600)
    assert {:ok, candidate} = persist(identity, t1, cycle)
    refute candidate.reset_at == original.reset_at
    assert candidate.reset_at == DateTime.add(cycle, 18_000)
    t2 = DateTime.add(t1, 180)
    assert {:ok, anchored} = persist(identity, t2, cycle)
    assert anchored.reset_at == DateTime.add(cycle, 18_000)
    refute anchored.metadata["reset_state"] == "floating"
  end

  test "a fresh API zero corrects positive model usage while older replay remains inert" do
    %{identity: identity} = active_upstream_assignment_fixture(pool_fixture(), %{})
    assert {:ok, used} = persist(identity, @start, @start, 35)
    t1 = DateTime.add(@start, 90)
    assert {:ok, candidate} = persist(identity, t1, t1)
    assert Decimal.equal?(used.used_percent, 35)
    assert Decimal.equal?(candidate.used_percent, 0)
    assert candidate.reset_at == DateTime.add(t1, 18_000)
    assert {:ok, replayed} = persist(identity, @start, @start, 35)
    assert Decimal.equal?(replayed.used_percent, 0)
    assert replayed.reset_at == candidate.reset_at
    assert replayed.observed_at == candidate.observed_at
  end

  defp persist(identity, at, cycle_start, used_percent \\ 0) do
    reset = DateTime.add(cycle_start, 18_000)

    payload = %{
      "additional_rate_limits" => [
        %{
          "limit_name" => "GPT-5.3-Codex-Spark",
          "metered_feature" => "gpt-5.3-codex-spark",
          "rate_limit" => %{
            "primary_window" => %{
              "used_percent" => used_percent,
              "limit_window_seconds" => 18_000,
              "reset_after_seconds" => DateTime.diff(reset, at),
              "reset_at" => DateTime.to_unix(reset)
            }
          }
        }
      ]
    }

    {:ok, [evidence]} = CodexParsers.parse_codex_usage_payload(payload, at)
    EvidenceStore.record_evidence(identity, evidence, at, at)
  end
end
