defmodule CodexPooler.Upstreams.Quota.AuthoritativeUsageTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures
  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias CodexPooler.Jobs.AccountReconciliationWorker
  alias CodexPooler.Metrics.AccountProjection
  alias CodexPooler.Upstreams.Quota.{AccountQuotaWindow, Windows, WindowSelector}
  alias CodexPoolerWeb.Admin.UpstreamAccountsReadModel.QuotaProjection
  alias CodexPoolerWeb.Admin.UpstreamPageComponents.AccountCard.QuotaLimitRow
  alias CodexPoolerWeb.DateTimeDisplay

  @now ~U[2026-09-07 10:00:00Z]

  test "fresh API 100 remaining and its reset win over ten-hour-old headers without warnings" do
    api = window(0, @now)

    header = %{
      window(98, DateTime.add(@now, -36_000))
      | source: "codex_response_headers",
        reset_at: DateTime.add(@now, 86_400)
    }

    for raw <- [[api, header], [header, api]] do
      assert [^api] = WindowSelector.logical_windows(raw, @now)
      row = weekly(raw, @now)
      assert row.percent_label == "100%"
      assert row.reset_at == api.reset_at
      assert row.selected_source == "codex_usage_api"
      assert length(row.observations) == 2
      html = render_component(&QuotaLimitRow.quota_limit_row/1, id: "api-weekly", limit: row)
      refute html =~ "Sources disagree"
      refute html =~ "sources differ"
      refute html =~ "Reset reports differ"
      refute html =~ "<details open"
      assert html =~ "98% used / 2% remaining"
      assert html =~ "Source diagnostics"
    end
  end

  test "headers cannot override API even when newer, nor invent an unsupported API meter" do
    api = window(4, DateTime.add(@now, -1_800))
    header = %{window(100, @now) | source: "codex_response_headers"}
    assert [^api] = WindowSelector.logical_windows([api, header], @now)
    assert weekly([api, header], @now).percent_label == "96%"
    assert weekly([api, header], @now).evidence_state == :stale
    assert WindowSelector.logical_windows([header], @now) == []
    assert weekly([header], @now).percent_label == "not reported"
    assert weekly([%{api | used_percent: nil}], @now).percent_label == "not reported"
  end

  test "newest API observation wins without using pressure or future resets as truth" do
    old = window(98, DateTime.add(@now, -60))
    fresh = %{window(0, @now) | reset_at: DateTime.add(@now, 86_400)}
    future = window(100, DateTime.add(@now, 1))
    assert [^fresh] = WindowSelector.logical_windows([old, future, fresh], @now)
    assert WindowSelector.best_account_window([old, fresh], :weekly_secondary, @now) == fresh
  end

  test "new API values and reset replace older API data, while late responses do not change age" do
    identity = active_upstream_identity_fixture()
    first_at = DateTime.utc_now() |> DateTime.add(-120) |> DateTime.truncate(:microsecond)
    second_at = DateTime.add(first_at, 60)
    first = window(98, first_at)
    second = %{window(0, second_at) | reset_at: DateTime.add(second_at, 86_400)}
    assert {:ok, [old]} = persist(identity, first)
    assert {:ok, [fresh]} = persist(identity, second)
    assert Decimal.equal?(fresh.used_percent, 0)
    assert fresh.reset_at == second.reset_at
    assert fresh.observed_at == second_at
    assert fresh.id == old.id
    assert {:ok, [late]} = persist(identity, first)
    assert Decimal.equal?(late.used_percent, fresh.used_percent)
    assert late.reset_at == fresh.reset_at
    assert late.observed_at == fresh.observed_at
    assert late.last_sync_at == fresh.last_sync_at
  end

  test "discrepancy ingestion enqueues one full API reconciliation across repeated observations and failures" do
    %{identity: identity, assignment: assignment} = active_upstream_assignment_fixture()
    Repo.delete_all(Oban.Job)
    at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    assert {:ok, [_]} = persist(identity, window(0, at))
    assert Repo.aggregate(Oban.Job, :count) == 0
    header = %{window(98, at) | source: "codex_response_headers"}
    for _ <- 1..20, do: assert({:ok, [_]} = persist(identity, header))
    assert [job] = all_enqueued(worker: AccountReconciliationWorker)
    assert job.args["upstream_identity_id"] == identity.id
    assert job.args["pool_upstream_assignment_id"] == assignment.id
    assert job.args["trigger_kind"] == "quota_source_disagreement"
    Repo.update_all(Oban.Job, set: [state: "discarded"])
    assert {:ok, [_]} = persist(identity, header)
    assert Repo.aggregate(Oban.Job, :count) == 1
  end

  test "matching reports do not enqueue, and API-only writes cannot create a discrepancy loop" do
    %{identity: identity} = active_upstream_assignment_fixture()
    Repo.delete_all(Oban.Job)
    at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    assert {:ok, [_]} = persist(identity, window(6, at))
    assert {:ok, [_]} = persist(identity, %{window(6, at) | source: "codex_response_headers"})
    assert Repo.aggregate(Oban.Job, :count) == 0
    assert {:ok, [_]} = persist(identity, window(0, DateTime.add(at, 1)))
    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  test "metrics select the API observation without writes, while retaining raw diagnostic samples" do
    %{identity: identity} = active_upstream_assignment_fixture()
    at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    assert {:ok, [_]} = persist(identity, window(0, at))
    assert {:ok, [_]} = persist(identity, %{window(98, at) | source: "codex_response_headers"})
    before_jobs = Repo.aggregate(Oban.Job, :count)

    raw =
      Enum.map(Windows.list_evidence(identity), fn window ->
        window
        |> Map.from_struct()
        |> Map.drop([:__meta__])
        |> Map.merge(%{index_model: "", index_upstream_model: ""})
      end)

    snapshot = %{
      as_of: at,
      memberships: [],
      windows: raw,
      identities: [
        Map.take(Map.from_struct(identity), [
          :id,
          :status,
          :disabled_at,
          :credential_provenance,
          :metadata
        ])
      ]
    }

    projection = AccountProjection.project(snapshot)
    assert projection.complete

    selected =
      Enum.filter(projection.samples, fn {name, labels, value} ->
        name == :account_quota_observation_routing_selected and value == 1 and
          labels[:account_id] == identity.id
      end)

    assert [{_, labels, 1}] = selected
    assert labels[:source] == "codex_usage_api"
    assert Repo.aggregate(Oban.Job, :count) == before_jobs
  end

  test "caller-owned transactions leave no job or cooldown claim, including after rollback" do
    %{identity: identity} = active_upstream_assignment_fixture()
    Repo.delete_all(Oban.Job)
    at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    assert {:ok, [_]} = persist(identity, window(0, at))
    header = %{window(98, at) | source: "codex_response_headers"}

    assert {:error, :cancelled} =
             Repo.transaction(fn ->
               assert {:ok, [_]} = persist(identity, header)
               assert Repo.aggregate(Oban.Job, :count) == 0
               Repo.rollback(:cancelled)
             end)

    assert length(Windows.list_evidence(identity)) == 1

    assert {:ok, _} =
             Repo.transaction(fn ->
               assert {:ok, [_]} = persist(identity, header)
               assert Repo.aggregate(Oban.Job, :count) == 0
             end)

    assert {:ok, [_]} = persist(identity, header)
    assert [_] = all_enqueued(worker: AccountReconciliationWorker)
  end

  test "cancelled jobs retain a bounded cooldown and old incomplete jobs still deduplicate" do
    %{identity: identity} = active_upstream_assignment_fixture()
    Repo.delete_all(Oban.Job)
    at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    header = %{window(98, at) | source: "codex_response_headers"}
    assert {:ok, [_]} = persist(identity, header)
    assert [job] = all_enqueued(worker: AccountReconciliationWorker)
    Repo.update_all(Oban.Job, set: [state: "cancelled"])
    assert {:ok, [_]} = persist(identity, header)
    assert Repo.aggregate(Oban.Job, :count) == 1
    Repo.update_all(Oban.Job, set: [inserted_at: DateTime.add(at, -61)])
    assert {:ok, [_]} = persist(identity, header)
    assert [replacement] = all_enqueued(worker: AccountReconciliationWorker)
    refute replacement.id == job.id

    Repo.update_all(from(j in Oban.Job, where: j.id == ^replacement.id),
      set: [state: "executing", inserted_at: DateTime.add(at, -3_600)]
    )

    assert {:ok, [_]} = persist(identity, header)
    assert Repo.aggregate(Oban.Job, :count) == 2
  end

  defp weekly(raw, at) do
    raw
    |> QuotaProjection.quota_limit_rows(DateTimeDisplay.preferences_for_user(nil), at, nil, raw)
    |> Enum.find(&(&1.key == :weekly))
  end

  defp persist(identity, window) do
    attrs =
      Map.from_struct(window)
      |> Map.drop([:__meta__, :id, :upstream_identity_id, :inserted_at, :created_at, :updated_at])

    Windows.upsert_quota_windows(identity, [attrs], delete_missing?: false)
  end

  defp window(used, observed_at) do
    %AccountQuotaWindow{
      id: Ecto.UUID.generate(),
      quota_key: "account",
      quota_scope: "account",
      quota_family: "account",
      window_kind: "secondary",
      window_minutes: 10_080,
      used_percent: Decimal.new(used),
      source: "codex_usage_api",
      source_precision: "authoritative",
      freshness_state: "fresh",
      observed_at: observed_at,
      last_sync_at: observed_at,
      reset_at: DateTime.add(observed_at, 604_800),
      metadata: %{},
      merge_precedence: 100
    }
  end
end
