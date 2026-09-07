defmodule CodexPooler.Upstreams.Quota.Windows.ProviderCycleConfirmationTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Quotas.Evidence
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Quota.Windows
  alias CodexPooler.Upstreams.Quota.Windows.EvidenceStore
  alias CodexPooler.Upstreams.SavedResets.AutoEligibility
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity
  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox

  @scenario_timeout_ms 5_000
  @detection_timeout_ms 15_000

  @old_reset ~U[2026-07-25 03:24:36Z]
  @new_reset ~U[2026-07-28 17:04:16Z]

  test "saved-reset auto eligibility rejects a legacy primary before source filtering and folding" do
    %{identity: identity, assignment: assignment} =
      active_upstream_assignment_fixture(pool_fixture(), %{})

    as_of = ~U[2026-07-22 12:00:00Z]
    legacy_at = DateTime.add(as_of, -2 * Evidence.freshness_ttl_seconds(), :second)
    current_at = DateTime.add(legacy_at, Evidence.freshness_ttl_seconds(), :second)

    insert_window!(identity, "primary", "codex_response_headers", legacy_at, @old_reset, "100")
    insert_window!(identity, "secondary", "codex_usage_api", current_at, @new_reset, "0")

    for snapshot_source <- ["codex_usage_api", "codex_response_headers"] do
      identity = enable_saved_reset_auto!(identity, snapshot_source, as_of)

      context = %{
        trigger: :blocked_weekly_exhaustion,
        pool_upstream_assignment_id: assignment.id,
        upstream_identity_id: identity.id,
        candidate_assignment_ids: [assignment.id],
        candidate_identity_ids: [identity.id],
        capacity_assignment_ids: [assignment.id],
        capacity_identity_ids: [identity.id],
        cohort_identity_ids: [identity.id],
        routable_assignment_ids: [assignment.id],
        routable_identity_ids: [identity.id],
        route_class: "proxy_http"
      }

      assert {:noop, "gateway_auto_trigger_not_current"} =
               AutoEligibility.validate_locked_gateway_auto(identity, assignment, context, as_of)
    end
  end

  @tag :provider_cycle_confirmation
  test "identity advisory lock serializes API authority against a runtime writer" do
    parent = self()
    barrier = make_ref()

    %{identity: identity, pool_id: pool_id} =
      unboxed(fn ->
        pool = pool_fixture()
        %{identity: identity} = active_upstream_assignment_fixture(pool, %{})
        canonical_at = ~U[2026-07-21 17:00:00Z]
        candidate_at = ~U[2026-07-21 17:04:00Z]

        provider_row!(identity, canonical_at, "54", @old_reset)
        runtime_row!(identity, canonical_at, "54", @old_reset)

        {:ok, _candidate} =
          record_provider(identity, candidate_at, "0", @new_reset, provider_at: candidate_at)

        %{identity: identity, pool_id: pool.id}
      end)

    on_exit(fn ->
      unboxed(fn ->
        identity |> Repo.reload!() |> Repo.delete!()
        pool_id |> CodexPooler.Pools.get_pool() |> Repo.delete!()
      end)
    end)

    blocker =
      Task.async(fn ->
        unboxed(fn ->
          Repo.transaction(fn ->
            backend_pid = backend_pid!()
            advisory_lock_identity!(identity.id)
            send(parent, {barrier, :blocker_locked, backend_pid})

            receive do
              {^barrier, :release} -> :ok
            after
              @scenario_timeout_ms -> raise "timed out waiting to release quota evidence lock"
            end

            record_provider(
              identity,
              ~U[2026-07-21 17:08:00Z],
              "0",
              @new_reset,
              provider_at: ~U[2026-07-21 17:08:00Z]
            )
          end)
        end)
      end)

    assert_receive {^barrier, :blocker_locked, blocker_backend_pid}, @detection_timeout_ms

    waiter =
      Task.async(fn ->
        unboxed(fn ->
          backend_pid = backend_pid!()
          send(parent, {barrier, :waiter_ready, backend_pid})

          result =
            runtime_row!(identity, ~U[2026-07-21 17:09:00Z], "1", @new_reset)

          {backend_pid, result.id}
        end)
      end)

    assert_receive {^barrier, :waiter_ready, waiter_backend_pid}, @detection_timeout_ms
    assert blocker_backend_pid != waiter_backend_pid
    assert_advisory_wait!(waiter_backend_pid, blocker_backend_pid)

    send(blocker.pid, {barrier, :release})
    assert {:ok, {:ok, _confirmed}} = Task.await(blocker, @detection_timeout_ms)
    assert {^waiter_backend_pid, runtime_id} = Task.await(waiter, @detection_timeout_ms)

    unboxed(fn ->
      confirmed = provider_row(identity)
      assert DateTime.compare(confirmed.reset_at, @new_reset) == :eq
      assert Decimal.equal?(confirmed.used_percent, 0)
      assert :none = EvidenceStore.parse_candidate(confirmed.metadata)
      assert Repo.get!(AccountQuotaWindow, runtime_id).source == "codex_rate_limit_event"

      assert Windows.quota_window_selection_data(identity, at: ~U[2026-07-21 17:09:00Z]).secondary.id ==
               confirmed.id
    end)
  end

  test "API positive corrections remain selected before runtime TTL" do
    for initial <- ["0", "2"] do
      identity = identity!()
      at = ~U[2026-07-21 17:00:00Z]
      provider_row!(identity, at, "95", @old_reset)
      runtime_row!(identity, at, "95", @old_reset)
      first = DateTime.add(at, 60)
      confirmed_at = DateTime.add(first, 180)
      provider_row!(identity, first, initial, @new_reset)
      provider_row!(identity, confirmed_at, initial, @new_reset)
      positive_at = DateTime.add(confirmed_at, 60)
      provider_row!(identity, positive_at, "3", @new_reset)
      row = provider_row(identity)
      assert :none = EvidenceStore.parse_candidate(row.metadata)
      assert Windows.list_quota_windows(identity, positive_at) == [row]
      assert Decimal.equal?(row.used_percent, Decimal.new("3"))
    end
  end

  test "API ordering and invalid provider timing preserve the accepted snapshot" do
    identity = identity!()
    at = ~U[2026-07-21 17:00:00Z]
    first = DateTime.add(at, 60)
    later = DateTime.add(first, 180)
    provider_row!(identity, at, "95", @old_reset)
    accepted = provider_row!(identity, first, "2", @new_reset)
    replay = provider_row!(identity, at, "98", @old_reset)
    assert replay.observed_at == accepted.observed_at
    assert Decimal.equal?(replay.used_percent, 2)

    for invalid_provider_at <- [DateTime.add(later, -3600), DateTime.add(later, 3600)] do
      assert {:error, %{code: :invalid_relative_weekly_timing}} =
               record_provider(identity, later, "3", @new_reset, provider_at: invalid_provider_at)

      current = provider_row(identity)
      assert current.observed_at == accepted.observed_at
      assert current.reset_at == accepted.reset_at
      assert Decimal.equal?(current.used_percent, accepted.used_percent)
    end

    corrected = provider_row!(identity, later, "3", DateTime.add(@new_reset, 180))
    assert DateTime.compare(corrected.reset_at, DateTime.add(@new_reset, 180)) == :eq
    assert Windows.quota_window_selection_data(identity, at: later).secondary.id == corrected.id
  end

  test "API changes apply without a confirmation delay and survive increasing usage" do
    identity = identity!()
    at = ~U[2026-07-21 17:00:00Z]
    provider_row!(identity, at, "95", @old_reset)
    runtime_row!(identity, at, "95", @old_reset)
    first = DateTime.add(at, 60)

    for {offset, used} <- [{0, "2"}, {179, "3"}, {180, "4"}] do
      observed_at = DateTime.add(first, offset)
      row = provider_row!(identity, observed_at, used, @new_reset)
      assert Decimal.equal?(row.used_percent, Decimal.new(used))
      assert :none = EvidenceStore.parse_candidate(row.metadata)
      assert Windows.quota_window_selection_data(identity, at: observed_at).secondary.id == row.id
    end

    next_cycle = DateTime.add(@new_reset, 86_400)
    next_at = DateTime.add(first, 240)
    row = provider_row!(identity, next_at, "1", next_cycle)
    assert DateTime.compare(row.reset_at, next_cycle) == :eq
    assert Decimal.equal?(row.used_percent, 1)
    assert :none = EvidenceStore.parse_candidate(row.metadata)
  end

  defp identity! do
    %{identity: identity} = active_upstream_assignment_fixture(pool_fixture(), %{})
    identity
  end

  defp provider_row!(identity, observed_at, percent, reset_at, opts \\ []) do
    provider_at = Keyword.get(opts, :provider_at, observed_at)

    {:ok, row} =
      record_provider(identity, observed_at, percent, reset_at, provider_at: provider_at)

    row
  end

  defp record_provider(identity, observed_at, percent, reset_at, opts) do
    provider_at = Keyword.fetch!(opts, :provider_at)

    EvidenceStore.record_evidence(
      identity,
      weekly_attrs("codex_usage_api", observed_at, percent, reset_at, opts)
      |> put_in([:metadata, "reset_after_seconds"], DateTime.diff(reset_at, provider_at, :second)),
      observed_at,
      observed_at
    )
  end

  defp runtime_row!(identity, observed_at, percent, reset_at) do
    {:ok, row} =
      EvidenceStore.record_evidence(
        identity,
        weekly_attrs("codex_rate_limit_event", observed_at, percent, reset_at),
        observed_at,
        observed_at
      )

    row
  end

  defp provider_row(identity) do
    Repo.one!(
      from window in AccountQuotaWindow,
        where: window.upstream_identity_id == ^identity.id,
        where: window.source == "codex_usage_api",
        where: window.quota_key == "account",
        where: window.window_kind == "secondary",
        where: window.window_minutes == 10_080
    )
  end

  defp advisory_lock_identity!(identity_id) do
    SQL.query!(Repo, "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [identity_id])
    :ok
  end

  defp backend_pid! do
    %{rows: [[backend_pid]]} = SQL.query!(Repo, "SELECT pg_backend_pid()", [])
    backend_pid
  end

  defp assert_advisory_wait!(waiter_pid, blocker_pid) do
    deadline = System.monotonic_time(:millisecond) + @detection_timeout_ms
    assert_advisory_wait!(waiter_pid, blocker_pid, deadline)
  end

  defp assert_advisory_wait!(waiter_pid, blocker_pid, deadline) do
    %{rows: rows} =
      SQL.query!(
        Repo,
        "SELECT pg_blocking_pids($1), wait_event_type FROM pg_stat_activity WHERE pid = $1",
        [waiter_pid]
      )

    if match?([[_, "Lock"]], rows) and blocker_pid in hd(hd(rows)) do
      :ok
    else
      if System.monotonic_time(:millisecond) < deadline do
        assert_advisory_wait!(waiter_pid, blocker_pid, deadline)
      else
        flunk("quota evidence writer never waited on the identity advisory lock")
      end
    end
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  defp weekly_attrs(source, observed_at, percent, reset_at, opts \\ []) do
    %{
      quota_key: "account",
      window_kind: "secondary",
      window_minutes: 10_080,
      used_percent: Decimal.new(percent),
      reset_at: reset_at,
      observed_at: observed_at,
      last_sync_at: observed_at,
      source: source,
      source_precision: "observed",
      quota_scope: "account",
      quota_family: "account",
      active_limit: Keyword.get(opts, :active_limit),
      credits: Keyword.get(opts, :credits),
      freshness_state: "fresh",
      metadata: %{}
    }
  end

  defp insert_window!(identity, kind, source, observed_at, reset_at, percent) do
    %AccountQuotaWindow{}
    |> AccountQuotaWindow.changeset(
      weekly_attrs(source, observed_at, percent, reset_at)
      |> Map.put(:upstream_identity_id, identity.id)
      |> Map.put(:window_kind, kind)
      |> Map.put(:created_at, observed_at)
      |> Map.put(:updated_at, observed_at)
    )
    |> Repo.insert!()
  end

  defp enable_saved_reset_auto!(identity, source, observed_at) do
    metadata =
      Map.put(identity.metadata || %{}, "saved_resets", %{
        "status" => "reported",
        "available_count" => 1,
        "source" => source,
        "path_style" => "codex_api",
        "observed_at" => DateTime.to_iso8601(observed_at),
        "usage_path" => "/api/codex/usage",
        "reason" => nil
      })

    identity
    |> UpstreamIdentity.changeset(%{
      metadata: metadata,
      saved_reset_auto_redeem_enabled: true,
      saved_reset_auto_redeem_min_blocked_minutes: 60,
      saved_reset_auto_redeem_keep_credits: 0,
      updated_at: observed_at
    })
    |> Repo.update!()
  end
end
