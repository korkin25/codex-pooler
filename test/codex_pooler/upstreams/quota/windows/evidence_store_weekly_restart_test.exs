defmodule CodexPooler.Upstreams.Quota.Windows.EvidenceStoreWeeklyRestartTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Quotas.Evidence
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Quota.Windows.EvidenceStore
  alias CodexPooler.Upstreams.Quota.Windows.Routing

  # Parser, ordering, and legacy metadata compatibility remain relevant under
  # API authority. Restart admission is covered by ApiSnapshotPersistenceTest.

  @window_seconds 10_080 * 60

  defp identity!(attrs \\ %{}) do
    %{identity: identity} = active_upstream_assignment_fixture(pool_fixture(), attrs)
    identity
  end

  defp exhausted_row!(identity, observed_at, opts \\ []) do
    used_row!(identity, observed_at, "100", opts)
  end

  defp used_row!(identity, observed_at, used_percent, opts \\ []) do
    reset_at = Keyword.get(opts, :reset_at, DateTime.add(observed_at, 5, :day))
    metadata = Keyword.get(opts, :metadata, %{})
    active_limit = Keyword.get(opts, :active_limit)
    credits = Keyword.get(opts, :credits)

    EvidenceStore.record_evidence(
      identity,
      %{
        quota_key: "account",
        window_kind: "secondary",
        window_minutes: 10_080,
        used_percent: Decimal.new(used_percent),
        reset_at: reset_at,
        observed_at: observed_at,
        last_sync_at: observed_at,
        source: "codex_usage_api",
        source_precision: "observed",
        quota_scope: "account",
        quota_family: "account",
        active_limit: active_limit,
        credits: credits,
        freshness_state: "fresh",
        metadata: metadata
      },
      observed_at,
      observed_at
    )
  end

  defp floating_zero(observed_at, opts \\ []) do
    reset_at = Keyword.get(opts, :reset_at, DateTime.add(observed_at, @window_seconds, :second))
    reset_after_seconds = Keyword.get(opts, :reset_after_seconds, @window_seconds)
    metadata = Keyword.get(opts, :metadata, %{})

    %{
      quota_key: "account",
      window_kind: "secondary",
      window_minutes: 10_080,
      used_percent: Decimal.new("0"),
      reset_at: reset_at,
      observed_at: observed_at,
      last_sync_at: observed_at,
      source: "codex_usage_api",
      source_precision: "observed",
      quota_scope: "account",
      quota_family: "account",
      freshness_state: "fresh",
      metadata: Map.put(metadata, "reset_after_seconds", reset_after_seconds)
    }
  end

  defp account_row(identity) do
    Repo.one(
      from w in AccountQuotaWindow,
        where:
          w.upstream_identity_id == ^identity.id and w.quota_key == "account" and
            w.window_kind == "secondary" and w.source == "codex_usage_api"
    )
  end

  test "candidate provider status rejects legacy, orphaned, malformed, mismatched, and unsafe state" do
    t0 = DateTime.utc_now() |> DateTime.add(-10, :minute) |> DateTime.truncate(:microsecond)

    cases = [
      {:legacy_candidate_without_status, fn metadata, _observed_at -> metadata end},
      {:orphan_status,
       fn metadata, observed_at ->
         metadata
         |> Map.delete("__quota_confirmed_candidate_v1")
         |> Map.put("__quota_candidate_provider_status_v1", safe_candidate_status(observed_at))
       end},
      {:malformed_status,
       fn metadata, observed_at ->
         Map.put(metadata, "__quota_candidate_provider_status_v1", %{
           "version" => 1,
           "allowed" => true,
           "limit_reached" => false,
           "observed_at" => DateTime.to_iso8601(observed_at),
           "extra" => true
         })
       end},
      {:timestamp_mismatch,
       fn metadata, observed_at ->
         Map.put(
           metadata,
           "__quota_candidate_provider_status_v1",
           safe_candidate_status(DateTime.add(observed_at, 1, :second))
         )
       end},
      {:non_boolean_status,
       fn metadata, observed_at ->
         Map.put(metadata, "__quota_candidate_provider_status_v1", %{
           "version" => 1,
           "allowed" => "true",
           "limit_reached" => false,
           "observed_at" => DateTime.to_iso8601(observed_at)
         })
       end},
      {:contradictory_status,
       fn metadata, observed_at ->
         Map.put(metadata, "__quota_candidate_provider_status_v1", %{
           "version" => 1,
           "allowed" => true,
           "limit_reached" => true,
           "observed_at" => DateTime.to_iso8601(observed_at)
         })
       end}
    ]

    for {_case_name, metadata_for} <- cases do
      identity = identity!()
      assert {:ok, _row} = exhausted_row!(identity, t0)
      candidate_at = DateTime.add(t0, 300, :second)

      assert {:ok, _row} =
               EvidenceStore.record_evidence(
                 identity,
                 floating_zero(candidate_at),
                 candidate_at,
                 candidate_at
               )

      row = account_row(identity)

      row
      |> Ecto.Changeset.change(metadata: metadata_for.(row.metadata, candidate_at))
      |> Repo.update!()

      reloaded = Repo.get!(AccountQuotaWindow, row.id)
      assert :none = EvidenceStore.parse_candidate_provider_status(reloaded.metadata)
      refute EvidenceStore.candidate_provider_status_safe?(reloaded.metadata)
    end
  end

  test "a later accepted positive observation clears candidate and provider status state" do
    t0 = DateTime.utc_now() |> DateTime.add(-10, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()
    canonical_reset = DateTime.add(t0, 5, :day)

    assert {:ok, _row} = exhausted_row!(identity, t0, reset_at: canonical_reset)

    candidate_at = DateTime.add(t0, 300, :second)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               floating_zero(candidate_at,
                 metadata: %{
                   "rate_limit_allowed" => true,
                   "rate_limit_reached" => false,
                   "reset_after_seconds" => @window_seconds
                 }
               ),
               candidate_at,
               candidate_at
             )

    assert {:ok, _row} =
             used_row!(identity, DateTime.add(candidate_at, 60, :second), "100",
               reset_at: canonical_reset
             )

    row = account_row(identity)
    refute Map.has_key?(row.metadata, "__quota_confirmed_candidate_v1")
    refute Map.has_key?(row.metadata, "__quota_candidate_provider_status_v1")
  end

  test "an anchored idle zero row keeps refreshing through the same-cycle sync" do
    # The chokepoint must NOT capture zero-over-zero observations: an anchored
    # idle account produces identical bodies (fixed reset, no usage), no
    # sliding proof can ever fire, and losing the same-cycle sync would starve
    # the row stale and fail routing closed on a perfectly healthy account.
    t0 = DateTime.utc_now() |> DateTime.add(-10, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()
    anchored_reset = DateTime.add(t0, 5, :day)

    assert {:ok, _row} =
             used_row!(identity, t0, "0",
               reset_at: anchored_reset,
               metadata: %{
                 "reset_after_seconds" => DateTime.diff(anchored_reset, t0, :second)
               }
             )

    for minute <- 1..16 do
      observed_at = DateTime.add(t0, minute, :minute)
      response_latency_seconds = 180
      persisted_at = DateTime.add(observed_at, response_latency_seconds, :second)

      remaining_seconds =
        DateTime.diff(anchored_reset, observed_at, :second) - response_latency_seconds

      assert {:ok, _row} =
               EvidenceStore.record_evidence(
                 identity,
                 floating_zero(observed_at,
                   reset_at: anchored_reset,
                   reset_after_seconds: remaining_seconds
                 ),
                 observed_at,
                 persisted_at
               )
    end

    row = account_row(identity)
    assert Decimal.compare(row.used_percent, Decimal.new("0")) == :eq
    assert DateTime.compare(row.observed_at, DateTime.add(t0, 16, :minute)) == :eq
    assert Evidence.current_freshness_state(row, DateTime.add(t0, 16, :minute)) == "fresh"
    assert row.freshness_state == "fresh"

    assert %{eligible?: true, routing_state: :weekly_only_probe} =
             Routing.eligibility_from_windows([row], at: row.observed_at)
  end

  test "a first weekly row with present invalid relative timing is rejected" do
    observed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    for reset_after_seconds <- [
          "invalid",
          @window_seconds + 20 * 60,
          @window_seconds - 10 * 60
        ] do
      identity = identity!()

      attrs =
        observed_at
        |> floating_zero(reset_after_seconds: reset_after_seconds)
        |> Map.put(:used_percent, Decimal.new("31"))

      assert {:error, %{code: :invalid_relative_weekly_timing}} =
               EvidenceStore.record_evidence(identity, attrs, observed_at, observed_at)

      assert account_row(identity) == nil
    end
  end

  test "sliding live zeroes keep an accepted weekly zero fresh beyond the ttl" do
    t0 = DateTime.utc_now() |> DateTime.add(-20, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()

    assert {:ok, _row} =
             used_row!(identity, t0, "0", reset_at: DateTime.add(t0, @window_seconds, :second))

    for minute <- 1..16 do
      observed_at = DateTime.add(t0, minute, :minute)

      assert {:ok, _row} =
               EvidenceStore.record_evidence(
                 identity,
                 floating_zero(observed_at),
                 observed_at,
                 observed_at
               )
    end

    row = account_row(identity)
    assert DateTime.diff(row.observed_at, t0, :minute) >= 12
    assert Evidence.current_freshness_state(row, DateTime.add(t0, 16, :minute)) == "fresh"
  end

  test "delayed sliding zeroes cannot clear a newer partially-used observation" do
    t0 = DateTime.utc_now() |> DateTime.add(-20, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()
    canonical_at = DateTime.add(t0, 10, :minute)
    assert {:ok, _row} = used_row!(identity, canonical_at, "31")

    delayed_first_at = DateTime.add(t0, 2, :minute)
    delayed_second_at = DateTime.add(t0, 6, :minute)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               delayed_first_at
               |> floating_zero()
               |> Map.put(:active_limit, 100)
               |> Map.put(:credits, 100),
               delayed_first_at,
               canonical_at
             )

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               delayed_second_at
               |> floating_zero()
               |> Map.put(:active_limit, 100)
               |> Map.put(:credits, 100),
               delayed_second_at,
               canonical_at
             )

    row = account_row(identity)
    assert Decimal.compare(row.used_percent, Decimal.new("31")) == :eq
    assert DateTime.compare(row.observed_at, canonical_at) == :eq
  end

  defp safe_candidate_status(observed_at) do
    %{
      "version" => 1,
      "allowed" => true,
      "limit_reached" => false,
      "observed_at" => DateTime.to_iso8601(observed_at)
    }
  end
end
