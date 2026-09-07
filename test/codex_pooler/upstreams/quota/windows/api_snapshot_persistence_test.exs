defmodule CodexPooler.Upstreams.Quota.Windows.ApiSnapshotPersistenceTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures
  alias CodexPooler.Upstreams.Quota.Windows
  alias CodexPooler.Upstreams.Quota.Windows.EvidenceStore

  @now ~U[2026-09-07 10:00:00.000000Z]
  @descriptors [
    {"account", %{quota_key: "account", quota_scope: "account", quota_family: "account"}},
    {"model",
     %{
       quota_key: "codex_spark",
       quota_scope: "model",
       quota_family: "codex_model",
       model: "gpt-5.3-codex-spark"
     }},
    {"upstream model",
     %{
       quota_key: "codex_spark",
       quota_scope: "upstream_model",
       quota_family: "codex_model",
       upstream_model: "provider-spark"
     }},
    {"feature",
     %{
       quota_key: "reserve",
       quota_scope: "feature",
       quota_family: "additional_limit",
       raw_metered_feature: "reserve-meter"
     }}
  ]

  @windows [
    {"5h", "primary", 300},
    {"weekly", "secondary", 10_080},
    {"monthly", "primary", 43_200}
  ]

  # API response values, including decreases and earlier reset corrections, are
  # authoritative on the first observation. Runtime corroboration, synthetic
  # provider watermarks, and repeated zero bodies are not admission conditions.
  for {scope, descriptor} <- @descriptors,
      {duration, kind, minutes} <- @windows,
      {scenario, used, reset_shift} <- [
        {"same reset zero", 0, 0},
        {"earlier reset zero", 0, -3600},
        {"later reset zero", 0, 3600},
        {"partial decrease", 17, 0},
        {"increase", 100, 0}
      ] do
    test "#{scope} #{duration} accepts fresh API #{scenario} immediately and keeps raw headers separate" do
      identity = active_upstream_identity_fixture()

      descriptor =
        unquote(
          Macro.escape(Map.merge(descriptor, %{window_kind: kind, window_minutes: minutes}))
        )

      old = attrs(descriptor, @now, 98)
      assert {:ok, previous} = Windows.record_evidence(identity, old, @now)
      observed_at = DateTime.add(@now, 60)

      incoming =
        attrs(descriptor, observed_at, unquote(used))
        |> Map.put(:reset_at, DateTime.add(old.reset_at, unquote(reset_shift)))

      assert {:ok, current} = Windows.record_evidence(identity, incoming, observed_at)
      assert current.id == previous.id
      assert Decimal.equal?(current.used_percent, unquote(used))
      assert current.reset_at == incoming.reset_at
      assert current.observed_at == observed_at
      assert current.active_limit == nil
      assert current.credits == nil
      assert :none = EvidenceStore.parse_candidate(current.metadata)

      header_at = DateTime.add(observed_at, 1)
      header = attrs(descriptor, header_at, 100) |> Map.put(:source, "codex_response_headers")
      assert {:ok, _} = Windows.record_evidence(identity, header, header_at)
      assert [selected] = Windows.list_quota_windows(identity, header_at)
      assert selected.id == current.id
      assert Decimal.equal?(selected.used_percent, unquote(used))
      assert length(Windows.list_evidence(identity)) == 2
    end
  end

  for {scope, descriptor} <- @descriptors,
      {duration, kind, minutes} <- @windows,
      offset <- [-60, 0] do
    test "#{scope} #{duration} ignores API observation offset #{offset}, including freshness and reset" do
      identity = active_upstream_identity_fixture()

      descriptor =
        unquote(
          Macro.escape(Map.merge(descriptor, %{window_kind: kind, window_minutes: minutes}))
        )

      assert {:ok, current} = Windows.record_evidence(identity, attrs(descriptor, @now, 30), @now)
      current = Repo.reload!(current)
      late_at = DateTime.add(@now, unquote(offset))

      assert {:ok, unchanged} =
               Windows.record_evidence(identity, attrs(descriptor, late_at, 100), @now)

      for key <- [:id, :used_percent, :reset_at, :observed_at, :last_sync_at, :metadata] do
        assert Map.fetch!(unchanged, key) == Map.fetch!(current, key)
      end
    end
  end

  for {scope, descriptor} <- @descriptors, {duration, kind, minutes} <- @windows do
    test "#{scope} #{duration} keeps omitted API measurements unknown instead of carrying old capacity" do
      identity = active_upstream_identity_fixture()

      descriptor =
        unquote(
          Macro.escape(Map.merge(descriptor, %{window_kind: kind, window_minutes: minutes}))
        )

      old = attrs(descriptor, @now, 98) |> Map.merge(%{active_limit: 243, credits: 5})
      assert {:ok, _} = Windows.record_evidence(identity, old, @now)
      at = DateTime.add(@now, 60)
      incoming = attrs(descriptor, at, 0) |> Map.drop([:used_percent, :reset_at])
      assert {:ok, current} = Windows.record_evidence(identity, incoming, at)
      assert current.used_percent == nil
      assert current.reset_at == nil
      assert current.active_limit == nil
      assert current.credits == nil
      refute Windows.usable_window?(current, at)
    end
  end

  defp attrs(descriptor, observed_at, used) do
    Map.merge(descriptor, %{
      used_percent: Decimal.new(used),
      reset_at: DateTime.add(@now, descriptor.window_minutes * 60),
      observed_at: observed_at,
      last_sync_at: observed_at,
      source: "codex_usage_api",
      source_precision: "observed",
      freshness_state: "fresh"
    })
  end
end
