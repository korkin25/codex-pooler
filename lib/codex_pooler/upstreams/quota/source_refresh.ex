defmodule CodexPooler.Upstreams.Quota.SourceRefresh do
  @moduledoc false

  require Logger

  alias CodexPooler.Jobs.UpstreamEnqueue
  alias CodexPooler.Quotas.SourceObservations
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Assignments.PoolAssignments
  alias CodexPooler.Upstreams.Quota.Windows.EvidenceStore

  @runtime_sources ~w(codex_response_headers codex_rate_limit_event codex_rate_limit_error)

  # Ingestion only; API responses cannot trigger a refresh loop. Enqueue only
  # after commit: Oban unique inserts use a nested transaction, so a failed
  # insert cannot be safely isolated inside a caller-owned transaction. Those
  # writes are covered by the existing periodic account reconciliation sweep.
  def after_ingest(identity, windows) do
    runtime = Enum.filter(windows, &(&1.source in @runtime_sources))

    if runtime != [] and not Repo.in_transaction?() do
      safely_enqueue(fn -> enqueue_mismatch(identity, runtime) end)
    end

    :ok
  end

  defp enqueue_mismatch(identity, runtime) do
    with assignment when not is_nil(assignment) <-
           PoolAssignments.canonical_active_assignment_for_identity(identity),
         true <-
           SourceObservations.api_refresh_needed?(
             runtime,
             EvidenceStore.list_evidence(identity),
             DateTime.utc_now()
           ) do
      UpstreamEnqueue.enqueue_quota_source_reconciliation(assignment)
    else
      _unchanged_or_inactive -> :ok
    end
  end

  # No caller transaction is open here. A scheduling failure is independent of
  # the committed observation, and does not claim any in-memory cooldown gate.
  defp safely_enqueue(enqueue) do
    case enqueue.() do
      {:error, _reason} -> log_failure()
      _enqueued_or_unchanged -> :ok
    end
  rescue
    _error -> log_failure()
  end

  defp log_failure, do: Logger.warning("quota discrepancy reconciliation enqueue failed")
end
