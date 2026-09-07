defmodule CodexPooler.Upstreams.Quota.Windows.ApiParserAuthorityTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures
  alias CodexPooler.Quotas.Evidence
  alias CodexPooler.Upstreams.Quota.{AccountQuotaWindow, Windows}
  alias CodexPooler.Upstreams.Quota.Windows.EvidenceStore

  @meters [
    {:account, 300},
    {:account, 10_080},
    {:account, 43_200},
    {:spark, 300},
    {:spark, 10_080},
    {:reserve, 10_080}
  ]

  for {meter, minutes} <- @meters,
      {scenario, used, shift} <- [
        {:zero, 0, 0},
        {:earlier, 0, -3600},
        {:later, 0, 3600},
        {:decrease, 17, 0},
        {:increase, 100, 0}
      ] do
    test "public usage parser #{meter}/#{minutes} accepts newest #{scenario} and fences old/equal responses" do
      identity = active_upstream_identity_fixture()
      old_at = DateTime.utc_now() |> DateTime.add(-120) |> DateTime.truncate(:second)
      at = DateTime.add(old_at, 60)
      reset = DateTime.add(old_at, unquote(minutes) * 60)
      first = payload(unquote(meter), unquote(minutes), 98, reset)
      latest_reset = DateTime.add(reset, unquote(shift))
      latest = payload(unquote(meter), unquote(minutes), unquote(used), latest_reset)

      assert {:ok, [old]} =
               Windows.upsert_quota_windows_from_codex_usage_payload(identity, first, old_at)

      assert {:ok, [current]} =
               Windows.upsert_quota_windows_from_codex_usage_payload(identity, latest, at)

      assert current.id == old.id
      assert current.source == "codex_usage_api"

      assert current.window_kind ==
               if(unquote(minutes) == 10_080, do: "secondary", else: "primary")

      assert Decimal.equal?(current.used_percent, unquote(used))
      assert DateTime.compare(current.reset_at, latest_reset) == :eq
      assert DateTime.compare(current.observed_at, at) == :eq

      assert :none =
               EvidenceStore.parse_candidate(current.metadata)

      assert current.quota_scope == if(unquote(meter) == :account, do: "account", else: "model")

      assert current.quota_key ==
               %{account: "account", spark: "codex_spark", reserve: "reserve"}[unquote(meter)]

      if unquote(meter) != :account, do: assert(current.raw_metered_feature != nil)

      for late_at <- [old_at, at] do
        assert {:ok, [unchanged]} =
                 Windows.upsert_quota_windows_from_codex_usage_payload(identity, first, late_at)

        assert unchanged.id == current.id
        assert Decimal.equal?(unchanged.used_percent, current.used_percent)
        assert unchanged.reset_at == current.reset_at
        assert unchanged.observed_at == current.observed_at
        assert unchanged.last_sync_at == current.last_sync_at
      end

      assert {:error, %{code: :upstream_quota_unusable}} =
               Windows.upsert_quota_windows_from_codex_usage_payload(
                 identity,
                 %{"rate_limit" => nil, "additional_rate_limits" => []},
                 DateTime.add(at, 1)
               )

      assert [selected] = Windows.list_quota_windows(identity, at)
      assert selected.id == current.id
      assert selected.observed_at == current.observed_at
      assert Decimal.equal?(selected.used_percent, current.used_percent)
    end
  end

  for meter <- [:account, :spark], minutes <- [300, 10_080], used <- [0, 17] do
    test "relative parser #{meter}/#{minutes} accepts latest #{used} percent with its reset" do
      identity = active_upstream_identity_fixture()
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      old_at = DateTime.add(now, -120)
      at = DateTime.add(now, -60)

      assert {:ok, [_]} =
               Windows.upsert_quota_windows_from_codex_usage_payload(
                 identity,
                 payload(
                   unquote(meter),
                   unquote(minutes),
                   98,
                   DateTime.add(old_at, unquote(minutes) * 60)
                 ),
                 old_at
               )

      relative_window = %{
        "used_percent" => unquote(used),
        "limit_window_seconds" => unquote(minutes) * 60,
        "reset_after_seconds" => unquote(minutes) * 60 - 180
      }

      body = payload(unquote(meter), unquote(minutes), unquote(used), at)

      body =
        if unquote(meter) == :account do
          put_in(body, ["rate_limit", "primary_window"], relative_window)
        else
          [entry] = body["additional_rate_limits"]

          %{
            body
            | "additional_rate_limits" => [
                put_in(entry, ["rate_limit", "primary_window"], relative_window)
              ]
          }
        end

      assert {:ok, [current]} =
               Windows.upsert_quota_windows_from_codex_usage_payload(identity, body, at)

      assert Decimal.equal?(current.used_percent, unquote(used))

      if unquote(minutes) == 10_080 do
        # Weekly countdown-only input does not supply an absolute reset. Keep
        # that parser uncertainty instead of carrying an older API reset.
        assert current.reset_at == nil
        refute Windows.usable_window?(current, now)
      else
        assert DateTime.compare(current.reset_at, DateTime.add(at, unquote(minutes) * 60 - 180)) ==
                 :eq
      end

      assert current.metadata["reset_after_seconds"] == unquote(minutes) * 60 - 180
      assert [selected] = Windows.list_quota_windows(identity, now)
      assert selected.id == current.id
      assert Decimal.equal?(selected.used_percent, unquote(used))
    end
  end

  for scope <- ["model", "upstream_model"] do
    test "parsed Spark updates one historical alias in #{scope} without crossing scope" do
      identity = active_upstream_identity_fixture()
      old_at = DateTime.utc_now() |> DateTime.add(-120) |> DateTime.truncate(:second)
      at = DateTime.add(old_at, 60)
      reset = DateTime.add(at, 604_800)

      assert {:ok, [parsed]} =
               Windows.codex_usage_quota_windows_from_payload(
                 payload(:spark, 10_080, 98, reset),
                 old_at
               )

      attrs =
        Map.merge(parsed, %{
          quota_scope: unquote(scope),
          model: if(unquote(scope) == "model", do: parsed.model, else: nil),
          upstream_model: if(unquote(scope) == "upstream_model", do: parsed.model, else: nil)
        })

      legacy =
        attrs
        |> Map.merge(%{
          upstream_identity_id: identity.id,
          quota_key: "gpt_5_3_codex_spark",
          created_at: old_at,
          updated_at: old_at
        })

      historical = %AccountQuotaWindow{} |> AccountQuotaWindow.changeset(legacy) |> Repo.insert!()
      other_scope = if unquote(scope) == "model", do: "upstream_model", else: "model"

      other =
        Map.merge(attrs, %{
          quota_scope: other_scope,
          model: if(other_scope == "model", do: parsed.model, else: nil),
          upstream_model: if(other_scope == "upstream_model", do: parsed.model, else: nil)
        })

      assert {:ok, [isolated]} = Windows.upsert_quota_windows(identity, [other])

      assert {:ok, [fresh_parsed]} =
               Windows.codex_usage_quota_windows_from_payload(
                 payload(:spark, 10_080, 0, DateTime.add(reset, -3600)),
                 at
               )

      {:ok, evidence} =
        Evidence.new(
          Map.merge(fresh_parsed, Map.take(attrs, [:quota_scope, :model, :upstream_model]))
        )

      assert {:ok, [current]} =
               Windows.upsert_quota_windows(identity, [Evidence.to_window_attrs(evidence)])

      assert current.id == historical.id
      assert current.quota_key == "codex_spark"
      assert current.quota_scope == unquote(scope)
      assert Decimal.equal?(current.used_percent, 0)
      assert current.raw_metered_feature == "codex_bengalfox"
      assert length(Windows.list_evidence(identity)) == 2
      assert length(Windows.list_quota_windows(identity, at)) == 2
      assert Decimal.equal?(Repo.reload!(isolated).used_percent, 98)
    end
  end

  for scope <- [:account, :spark], invalid <- [:malformed, :inconsistent, :future] do
    test "newer #{scope} API update with #{invalid} relative timing leaves existing row untouched" do
      identity = active_upstream_identity_fixture()
      timestamp = DateTime.utc_now() |> DateTime.truncate(:second)
      old_at = DateTime.add(timestamp, -60)
      reset = DateTime.add(timestamp, 604_800)

      assert {:ok, [old]} =
               Windows.upsert_quota_windows_from_codex_usage_payload(
                 identity,
                 payload(unquote(scope), 10_080, 98, reset),
                 old_at
               )

      baseline = Repo.reload!(old)

      assert {:ok, [attrs]} =
               Windows.codex_usage_quota_windows_from_payload(
                 payload(unquote(scope), 10_080, 0, reset),
                 timestamp
               )

      attrs =
        case unquote(invalid) do
          :malformed ->
            Map.put(attrs, :metadata, %{"reset_after_seconds" => "bad"})

          :inconsistent ->
            Map.put(attrs, :metadata, %{"reset_after_seconds" => 603_600})

          :future ->
            attrs
            |> Map.put(:reset_at, DateTime.add(reset, 600))
            |> Map.put(:metadata, %{"reset_after_seconds" => 604_800})
        end

      assert {:error, %{code: :invalid_relative_weekly_timing}} =
               Windows.record_evidence(identity, attrs, timestamp)

      assert Repo.reload!(old) == baseline
      assert [selected] = Windows.list_quota_windows(identity, timestamp)
      assert Decimal.equal?(selected.used_percent, 98)
      recovered_at = DateTime.add(timestamp, 1)

      assert {:ok, [recovered]} =
               Windows.upsert_quota_windows_from_codex_usage_payload(
                 identity,
                 payload(unquote(scope), 10_080, 0, reset),
                 recovered_at
               )

      assert recovered.id == old.id
      assert Decimal.equal?(recovered.used_percent, 0)
      assert DateTime.compare(recovered.observed_at, recovered_at) == :eq
    end
  end

  defp payload(meter, minutes, used, reset) do
    window = %{
      "used_percent" => used,
      "limit_window_seconds" => minutes * 60,
      "reset_at" => DateTime.to_unix(reset)
    }

    # Weekly deliberately arrives in the provider's primary slot, exercising
    # duration normalization through the public ingestion facade.
    rate_limit = %{"primary_window" => window}

    case meter do
      :account ->
        %{"rate_limit" => rate_limit}

      :spark ->
        %{
          "additional_rate_limits" => [
            %{
              "limit_name" => "GPT-5.3-Codex-Spark",
              "metered_feature" => "codex_bengalfox",
              "model" => "gpt-5.3-codex-spark",
              "rate_limit" => rate_limit
            }
          ]
        }

      :reserve ->
        %{
          "additional_rate_limits" => [
            %{
              "limit_name" => "Reserve",
              "metered_feature" => "reserve-meter",
              "model" => "reserve-model",
              "rate_limit" => rate_limit
            }
          ]
        }
    end
  end
end
