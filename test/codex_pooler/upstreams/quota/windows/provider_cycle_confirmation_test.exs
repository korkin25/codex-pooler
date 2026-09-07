defmodule CodexPooler.Upstreams.Quota.Windows.ProviderCycleConfirmationTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Quotas.Evidence
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.SavedResets.AutoEligibility
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

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
