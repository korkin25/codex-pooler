defmodule CodexPooler.Upstreams.Quota.Windows.EvidenceStoreModelWeeklyRestartTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Accounting.UsageResponses
  alias CodexPooler.Quotas.{AdditionalMeterIdentity, Evidence, ModelWeeklyResetSemantics}
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Quota.Windows
  alias CodexPooler.Upstreams.Quota.Windows.CycleConfirmation
  alias CodexPooler.Upstreams.Quota.Windows.EvidenceStore
  alias CodexPooler.Upstreams.Quota.WindowSelector

  @window_seconds 10_080 * 60

  defp identity! do
    %{identity: identity} = active_upstream_assignment_fixture(pool_fixture(), %{})
    identity
  end

  defp model_weekly(observed_at, used_percent, opts \\ []) do
    reset_at = Keyword.get(opts, :reset_at, DateTime.add(observed_at, @window_seconds, :second))
    metadata = Keyword.get(opts, :metadata, %{"reset_after_seconds" => @window_seconds})

    %{
      quota_key: "codex_spark",
      window_kind: "secondary",
      window_minutes: 10_080,
      used_percent: Decimal.new(used_percent),
      reset_at: reset_at,
      observed_at: observed_at,
      last_sync_at: observed_at,
      source: "codex_usage_api",
      source_precision: "observed",
      quota_scope: "model",
      quota_family: "codex_model",
      model: "gpt-5.3-codex-spark",
      freshness_state: "fresh",
      metadata: metadata
    }
  end

  defp model_weekly_row(identity) do
    Repo.one(
      from w in AccountQuotaWindow,
        where:
          w.upstream_identity_id == ^identity.id and w.quota_key == "codex_spark" and
            w.window_kind == "secondary" and w.source == "codex_usage_api"
    )
  end

  defp identity_rows(identity) do
    Repo.all(
      from w in AccountQuotaWindow,
        where: w.upstream_identity_id == ^identity.id,
        order_by: [asc: w.id]
    )
  end

  defp persist_literal_window!(id, attrs) do
    changeset =
      %AccountQuotaWindow{id: id}
      |> AccountQuotaWindow.changeset(attrs)

    assert changeset.valid?, inspect(errors_on(changeset))
    Repo.insert!(changeset)
  end

  defp sorted_full_row_maps(identity) do
    schema_fields = AccountQuotaWindow.__schema__(:fields)

    identity
    |> identity_rows()
    |> Enum.map(fn row ->
      row_map = Map.take(row, schema_fields)
      assert Map.keys(row_map) |> Enum.sort() == Enum.sort(schema_fields)
      row_map
    end)
    |> Enum.sort_by(& &1.id)
  end

  defp full_row_snapshot(identity) do
    row_maps = sorted_full_row_maps(identity)
    %{row_maps: row_maps, bytes: :erlang.term_to_binary(row_maps)}
  end

  defp assert_full_row_snapshot_unchanged!(identity, baseline) do
    current = full_row_snapshot(identity)

    assert current.row_maps == baseline.row_maps
    assert current.bytes == baseline.bytes
    current
  end

  defp generic_weekly_payload(limit_name, metered_feature, used_percent, reset_at) do
    %{
      "additional_rate_limits" => [
        %{
          "limit_name" => limit_name,
          "metered_feature" => metered_feature,
          "rate_limit" => %{
            "primary_window" => %{
              "used_percent" => used_percent,
              "limit_window_seconds" => @window_seconds,
              "reset_after_seconds" => @window_seconds,
              "reset_at" => DateTime.to_unix(reset_at)
            }
          }
        }
      ]
    }
  end

  defp parsed_additional_weekly!(payload, observed_at) do
    assert {:ok, windows} = Windows.codex_usage_quota_windows_from_payload(payload, observed_at)

    assert [weekly] =
             Enum.filter(
               windows,
               &(&1.window_kind == "secondary" and &1.window_minutes == 10_080 and
                   &1.quota_scope == "model")
             )

    weekly
  end

  defp account_weekly(observed_at, used_percent) do
    observed_at
    |> model_weekly(used_percent)
    |> Map.merge(%{
      quota_key: "account",
      quota_scope: "account",
      quota_family: "account",
      model: nil
    })
  end

  defp assert_qf001_persistence!(insert_order, future_id, future_raw_limit_id) do
    as_of = ~U[2026-07-25 12:00:00.000000Z]
    identity = identity!()

    explicit_floating_attrs = %{
      upstream_identity_id: identity.id,
      quota_key: "codex_spark",
      window_kind: "secondary",
      window_minutes: 10_080,
      active_limit: nil,
      credits: nil,
      reset_at: ~U[2026-08-01 12:00:00.000000Z],
      used_percent: Decimal.new("0"),
      display_label: "GPT-5.3-Codex-Spark",
      limit_name: "gpt-5.3-codex-spark",
      metered_feature: "codex_spark",
      source: "codex_usage_api",
      source_precision: "observed",
      quota_scope: "model",
      quota_family: "codex_model",
      model: "gpt-5.3-codex-spark",
      upstream_model: nil,
      raw_limit_id: "qf001-usage",
      raw_limit_name: "gpt-5.3-codex-spark",
      raw_metered_feature: "codex_spark",
      freshness_state: "fresh",
      last_sync_at: ~U[2026-07-25 11:59:00.000000Z],
      observed_at: ~U[2026-07-25 11:59:00.000000Z],
      merge_precedence: 60,
      metadata: %{"reset_state" => "floating"},
      created_at: ~U[2026-07-25 11:59:00.000000Z],
      updated_at: ~U[2026-07-25 11:59:00.000000Z]
    }

    markerless_header_attrs = %{
      upstream_identity_id: identity.id,
      quota_key: "codex_spark",
      window_kind: "secondary",
      window_minutes: 10_080,
      active_limit: nil,
      credits: nil,
      reset_at: ~U[2026-08-01 12:30:00.000000Z],
      used_percent: Decimal.new("0"),
      display_label: "GPT-5.3-Codex-Spark",
      limit_name: "gpt-5.3-codex-spark",
      metered_feature: "codex_spark",
      source: "codex_response_headers",
      source_precision: "observed",
      quota_scope: "model",
      quota_family: "codex_model",
      model: "gpt-5.3-codex-spark",
      upstream_model: nil,
      raw_limit_id: "qf001-header",
      raw_limit_name: "gpt-5.3-codex-spark",
      raw_metered_feature: "codex_spark",
      freshness_state: "fresh",
      last_sync_at: ~U[2026-07-25 11:59:30.000000Z],
      observed_at: ~U[2026-07-25 11:59:30.000000Z],
      merge_precedence: 80,
      metadata: %{},
      created_at: ~U[2026-07-25 11:59:30.000000Z],
      updated_at: ~U[2026-07-25 11:59:30.000000Z]
    }

    future_boundary_attrs = %{
      upstream_identity_id: identity.id,
      quota_key: "codex_spark",
      window_kind: "secondary",
      window_minutes: 10_080,
      active_limit: nil,
      credits: nil,
      reset_at: ~U[2026-08-02 12:00:00.000001Z],
      used_percent: Decimal.new("100"),
      display_label: "GPT-5.3-Codex-Spark",
      limit_name: "gpt-5.3-codex-spark",
      metered_feature: "codex_spark",
      source: "codex_usage_api",
      source_precision: "observed",
      quota_scope: "model",
      quota_family: "codex_model",
      model: "gpt-5.3-codex-spark",
      upstream_model: nil,
      raw_limit_id: future_raw_limit_id,
      raw_limit_name: "gpt-5.3-codex-spark",
      raw_metered_feature: "codex_spark",
      freshness_state: "fresh",
      last_sync_at: ~U[2026-07-25 12:00:00.000001Z],
      observed_at: ~U[2026-07-25 12:00:00.000001Z],
      merge_precedence: 100,
      metadata: %{"reset_state" => "anchored"},
      created_at: ~U[2026-07-25 12:00:00.000001Z],
      updated_at: ~U[2026-07-25 12:00:00.000001Z]
    }

    row_specs = %{
      explicit_floating: %{
        id: "10000000-0000-4000-8000-000000000001",
        attrs: explicit_floating_attrs
      },
      markerless_header: %{
        id: "ffffffff-ffff-4fff-bfff-ffffffffffff",
        attrs: markerless_header_attrs
      }
    }

    assert insert_order in [
             [:explicit_floating, :markerless_header],
             [:markerless_header, :explicit_floating]
           ]

    persisted_rows =
      Enum.reduce(insert_order, %{}, fn row_name, rows ->
        %{id: id, attrs: attrs} = Map.fetch!(row_specs, row_name)
        Map.put(rows, row_name, persist_literal_window!(id, attrs))
      end)

    explicit_floating = Map.fetch!(persisted_rows, :explicit_floating)
    markerless_header = Map.fetch!(persisted_rows, :markerless_header)
    future_boundary = persist_literal_window!(future_id, future_boundary_attrs)

    assert Map.take(explicit_floating, Map.keys(explicit_floating_attrs)) ==
             explicit_floating_attrs

    assert Map.take(markerless_header, Map.keys(markerless_header_attrs)) ==
             markerless_header_attrs

    assert Map.take(future_boundary, Map.keys(future_boundary_attrs)) == future_boundary_attrs
    assert explicit_floating.id != markerless_header.id

    assert WindowSelector.logical_key(explicit_floating) ==
             WindowSelector.logical_key(markerless_header)

    assert WindowSelector.logical_key(explicit_floating) ==
             WindowSelector.logical_key(future_boundary)

    assert ModelWeeklyResetSemantics.classify(explicit_floating) == :anchored
    assert ModelWeeklyResetSemantics.classify(markerless_header) == :unknown
    assert ModelWeeklyResetSemantics.classify(future_boundary) == :anchored
    assert explicit_floating.metadata == %{"reset_state" => "floating"}
    assert markerless_header.metadata == %{}
    assert future_boundary.metadata == %{"reset_state" => "anchored"}
    assert future_boundary.observed_at == ~U[2026-07-25 12:00:00.000001Z]

    assert [future_winner] =
             WindowSelector.logical_windows(
               [explicit_floating, markerless_header, future_boundary],
               future_boundary.observed_at
             )

    assert future_winner.id == future_boundary.id

    baseline = full_row_snapshot(identity)

    expected_physical_ids =
      [
        "10000000-0000-4000-8000-000000000001",
        future_id,
        "ffffffff-ffff-4fff-bfff-ffffffffffff"
      ]
      |> Enum.sort()

    assert Enum.map(baseline.row_maps, & &1.id) == expected_physical_ids
    assert length(baseline.row_maps) == 3

    assert Enum.find(baseline.row_maps, &(&1.id == explicit_floating.id)).metadata == %{
             "reset_state" => "floating"
           }

    assert Enum.find(baseline.row_maps, &(&1.id == markerless_header.id)).metadata == %{}

    assert Enum.find(baseline.row_maps, &(&1.id == future_boundary.id)).metadata == %{
             "reset_state" => "anchored"
           }

    assert [effective_winner] = Windows.list_quota_windows(identity, as_of)
    assert effective_winner.id == explicit_floating.id
    refute effective_winner.id == future_boundary.id
    after_list = assert_full_row_snapshot_unchanged!(identity, baseline)
    assert length(after_list.row_maps) == 3

    selection = Windows.quota_window_selection_data(identity, at: as_of)

    assert [selection_winner] = selection.routing_windows
    assert selection_winner.id == explicit_floating.id
    refute Enum.any?(selection.routing_windows, &(&1.id == future_boundary.id))
    assert Enum.map(selection.windows, & &1.id) |> Enum.sort() == expected_physical_ids
    after_selection = assert_full_row_snapshot_unchanged!(identity, baseline)
    assert length(after_selection.row_maps) == 3

    assert [both_cycle_winner] = Windows.list_quota_windows(identity, as_of)
    both_cycle_selection = Windows.quota_window_selection_data(identity, at: as_of)

    assert both_cycle_winner.id == explicit_floating.id
    assert [both_cycle_selection_winner] = both_cycle_selection.routing_windows
    assert both_cycle_selection_winner.id == explicit_floating.id
    refute Enum.any?(both_cycle_selection.routing_windows, &(&1.id == future_boundary.id))

    assert Enum.map(both_cycle_selection.windows, & &1.id) |> Enum.sort() ==
             expected_physical_ids

    after_both = assert_full_row_snapshot_unchanged!(identity, baseline)
    assert Enum.map(after_both.row_maps, & &1.id) == expected_physical_ids
    assert length(after_both.row_maps) == 3
  end

  test "QF-001 explicit floating then markerless preserves rows and selects the API reset" do
    assert_qf001_persistence!(
      [:explicit_floating, :markerless_header],
      "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeee1",
      "qf001-future-explicit-first"
    )
  end

  test "QF-001 markerless then explicit floating preserves rows and selects the API reset" do
    assert_qf001_persistence!(
      [:markerless_header, :explicit_floating],
      "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeee2",
      "qf001-future-markerless-first"
    )
  end

  test "initial positive account evidence keeps the existing markerless reset-state behavior" do
    observed_at = ~U[2026-07-25 03:00:00Z]
    identity = identity!()

    assert {:ok, row} =
             EvidenceStore.record_evidence(
               identity,
               account_weekly(observed_at, "64"),
               observed_at,
               observed_at
             )

    refute Map.has_key?(row.metadata, "reset_state")
    refute Map.has_key?(row.metadata, "__quota_cycle_confirmation_v1")
    assert CycleConfirmation.valid_marker(row) == :none
    refute CycleConfirmation.selector_valid?(row, observed_at)
  end

  test "mixed-version generic and rich writers remain shared-postgres readable without schema changes" do
    observed_at = ~U[2026-08-25 09:00:00Z]
    reset_at = DateTime.add(observed_at, @window_seconds, :second)
    identity = identity!()

    rich_alpha =
      parsed_additional_weekly!(
        generic_weekly_payload("Example Weekly Model", "meter-alpha", 31, reset_at),
        observed_at
      )

    rich_beta =
      parsed_additional_weekly!(
        generic_weekly_payload("Example Weekly Model", "meter-beta", 72, reset_at),
        observed_at
      )

    generic = %{
      rich_alpha
      | metered_feature: nil,
        raw_limit_id: nil,
        raw_metered_feature: nil
    }

    assert advisory_lock_count() == 0

    assert {:ok, generic_row} =
             EvidenceStore.record_evidence(identity, generic, observed_at, observed_at)

    assert advisory_lock_count() >= 1

    assert [legacy_readable] = Windows.list_quota_windows(identity, observed_at)
    assert legacy_readable.id == generic_row.id
    assert AdditionalMeterIdentity.token(legacy_readable) == nil

    assert {:ok, alpha_row} =
             EvidenceStore.record_evidence(identity, rich_alpha, observed_at, observed_at)

    assert [alpha_effective] = Windows.list_quota_windows(identity, observed_at)
    assert AdditionalMeterIdentity.token(alpha_effective) == "meter-alpha"

    assert {:ok, beta_row} =
             EvidenceStore.record_evidence(identity, rich_beta, observed_at, observed_at)

    rows = identity_rows(identity)

    assert Enum.map(rows, & &1.id) |> Enum.sort() ==
             Enum.sort([generic_row.id, alpha_row.id, beta_row.id])

    assert rows
           |> Enum.map(&Evidence.logical_window_key/1)
           |> Enum.uniq()
           |> length() == 1

    assert [[index_definition]] =
             Repo.query!(
               "SELECT pg_get_indexdef(indexrelid) FROM pg_index WHERE indexrelid = 'account_quota_windows_evidence_identity_uq'::regclass"
             ).rows

    assert index_definition =~ "raw_metered_feature"

    duplicate_alpha =
      %AccountQuotaWindow{id: Ecto.UUID.generate()}
      |> AccountQuotaWindow.changeset(Map.from_struct(alpha_row))

    assert {:error, duplicate_changeset} = Repo.insert(duplicate_alpha, mode: :savepoint)

    assert duplicate_changeset.errors[:window_kind] ==
             {"has already been taken",
              [
                constraint: :unique,
                constraint_name: "account_quota_windows_evidence_identity_uq"
              ]}

    expected_public = [
      {"example_weekly_model", "meter-alpha", 31},
      {"example_weekly_model", "meter-beta", 72}
    ]

    for candidate_order <- permutations(rows) do
      assert candidate_order
             |> UsageResponses.additional_codex_rate_limits(observed_at)
             |> Enum.map(fn entry ->
               {entry.quota_key, entry.metered_feature,
                entry.rate_limit.secondary_window.used_percent}
             end) == expected_public
    end

    assert Windows.list_quota_windows(identity, observed_at)
           |> Enum.map(&AdditionalMeterIdentity.token/1) == ["meter-alpha", "meter-beta"]
  end

  defp permutations([]), do: [[]]

  defp permutations(items) do
    for item <- items,
        rest <- permutations(List.delete(items, item)),
        do: [item | rest]
  end

  defp advisory_lock_count do
    assert [[count]] =
             Repo.query!(
               "SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND pid = pg_backend_pid() AND granted"
             ).rows

    count
  end

  test "a first model weekly row with present invalid relative timing is rejected" do
    observed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    for reset_after_seconds <- [
          "invalid",
          @window_seconds + 20 * 60,
          @window_seconds - 10 * 60
        ] do
      identity = identity!()

      attrs =
        model_weekly(observed_at, "64", metadata: %{"reset_after_seconds" => reset_after_seconds})

      assert {:error, %{code: :invalid_relative_weekly_timing}} =
               EvidenceStore.record_evidence(identity, attrs, observed_at, observed_at)

      assert model_weekly_row(identity) == nil
    end
  end
end
