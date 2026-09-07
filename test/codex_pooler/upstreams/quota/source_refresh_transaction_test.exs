defmodule CodexPooler.Upstreams.Quota.SourceRefreshTransactionTest do
  use ExUnit.Case, async: false
  use Oban.Testing, repo: CodexPooler.Repo
  import Ecto.Query
  import CodexPooler.PoolerFixtures
  alias CodexPooler.Jobs.AccountReconciliationWorker
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Assignments.PoolAssignments
  alias CodexPooler.Upstreams.Quota.{AccountQuotaWindow, Windows}
  alias Ecto.Adapters.SQL.Sandbox

  # Real commits are essential: a sandbox outer transaction would mask an
  # enqueue exception poisoning the request's own transaction.
  setup do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    on_exit(fn -> Sandbox.checkin(Repo) end)
    :ok
  end

  test "SQL enqueue failure cannot undo committed evidence, and leaves no cooldown claim" do
    pool = pool_fixture()
    identity = active_upstream_identity_fixture()
    {:ok, assignment} = PoolAssignments.create_pool_assignment(pool, identity, %{})
    {:ok, assignment} = PoolAssignments.activate_pool_assignment(assignment)
    at = DateTime.utc_now()

    attrs = %{
      quota_key: "account",
      quota_scope: "account",
      quota_family: "account",
      window_kind: "secondary",
      window_minutes: 10_080,
      used_percent: Decimal.new(98),
      reset_at: DateTime.add(at, 604_800),
      observed_at: at,
      last_sync_at: at,
      source: "codex_response_headers",
      source_precision: "observed",
      freshness_state: "fresh"
    }

    Repo.query!("""
    CREATE FUNCTION pg_temp.reject_quota_job() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN RAISE EXCEPTION 'synthetic-enqueue-error'; END $$
    """)

    Repo.query!("""
    CREATE TRIGGER reject_quota_job BEFORE INSERT ON oban_jobs
    FOR EACH ROW WHEN (NEW.args->>'trigger_kind' = 'quota_source_disagreement')
    EXECUTE FUNCTION pg_temp.reject_quota_job()
    """)

    try do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, [stored]} = Windows.upsert_quota_windows(identity, [attrs])
          assert Decimal.equal?(stored.used_percent, 98)
        end)

      assert log =~ "quota discrepancy reconciliation enqueue failed"
      refute log =~ "synthetic-enqueue-error"
      assert [stored] = Windows.list_evidence(identity)
      assert Decimal.equal?(stored.used_percent, 98)

      assert [] =
               all_enqueued(
                 worker: AccountReconciliationWorker,
                 args: %{upstream_identity_id: identity.id}
               )

      Repo.query!("DROP TRIGGER reject_quota_job ON oban_jobs")
      assert {:ok, [_]} = Windows.upsert_quota_windows(identity, [attrs])

      assert [job] =
               all_enqueued(
                 worker: AccountReconciliationWorker,
                 args: %{upstream_identity_id: identity.id}
               )

      assert job.args["trigger_kind"] == "quota_source_disagreement"
    after
      Repo.query!("DROP TRIGGER IF EXISTS reject_quota_job ON oban_jobs")
      Repo.delete_all(from j in Oban.Job, where: j.args["upstream_identity_id"] == ^identity.id)
      Repo.delete_all(from w in AccountQuotaWindow, where: w.upstream_identity_id == ^identity.id)
      Repo.delete!(assignment)
      Repo.delete!(identity)
      Repo.delete!(pool)
    end
  end
end
