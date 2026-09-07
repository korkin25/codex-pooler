defmodule CodexPooler.Catalog.SyncCardinalityTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Catalog.{Model, Sync}
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams

  test "repeated discovery and case variants reuse one row per pool and exposed id" do
    pool = pool_fixture()
    first = source(pool)
    second = source(pool)

    fetcher = fn source ->
      {:ok,
       [
         %{"id" => "sample-shared", "annotation" => nil},
         %{"id" => "SAMPLE-SHARED", "annotation" => "observed", "supports_tools" => true}
       ] ++
         if(source.assignment.id == first.assignment.id,
           do: [%{"id" => "sample-shared"}],
           else: []
         )}
    end

    assert {:ok, %{models: [model], sync_run: run}} =
             Sync.sync_pool_catalog(pool, fetcher: fetcher)

    assert run.discovered_model_count == 1
    assert run.upserted_model_count == 1
    assert model.source_assignment_count == 2
    assert model.metadata["upstream_model"]["annotation"] == "observed"
    assert model.supports_tools

    assert model.metadata["source_assignment_ids"] ==
             Enum.sort([first.assignment.id, second.assignment.id])

    assert {:ok, %{models: [repeated], sync_run: repeated_run}} =
             Sync.sync_pool_catalog(pool, fetcher: fetcher)

    assert repeated.id == model.id
    assert repeated.first_seen_at == model.first_seen_at
    assert repeated_run.upserted_model_count == 1
    assert count(pool) == 1

    other_pool = pool_fixture()
    source(other_pool)
    assert {:ok, %{models: [other]}} = Sync.sync_pool_catalog(other_pool, fetcher: fetcher)
    refute other.id == model.id
    assert count(other_pool) == 1
  end

  test "missing models remain stale rows and reappearance reactivates the same row" do
    pool = pool_fixture()
    source(pool)
    fetcher = fn _ -> {:ok, [%{"id" => "sample-returning"}]} end
    assert {:ok, %{models: [model]}} = Sync.sync_pool_catalog(pool, fetcher: fetcher)

    assert {:ok, %{models: [], sync_run: stale_run}} =
             Sync.sync_pool_catalog(pool, fetcher: fn _ -> {:ok, []} end)

    assert stale_run.stale_marked_count == 1
    assert Repo.reload!(model).status == "stale"
    assert count(pool) == 1

    assert {:ok, %{models: [returned]}} = Sync.sync_pool_catalog(pool, fetcher: fetcher)
    assert returned.id == model.id
    assert returned.status == "active"
    assert is_nil(returned.stale_at)
    assert returned.first_seen_at == model.first_seen_at
    assert count(pool) == 1
  end

  test "legacy malformed source metadata is normalized while failed assignments are preserved" do
    for previous_models <- [[], %{}] do
      pool = pool_fixture()
      failed = source(pool)
      healthy = source(pool)

      existing =
        model_fixture(pool, %{
          exposed_model_id: "sample-legacy",
          metadata: %{
            "source_assignment_ids" => [failed.assignment.id, failed.assignment.id, nil],
            "source_assignment_models" => previous_models,
            "source_assignment_missing_sync_run_ids" => []
          }
        })

      assert {:ok, %{models: [updated], partial?: true, sync_run: run}} =
               Sync.sync_pool_catalog(pool,
                 fetcher: fn source ->
                   if source.assignment.id == failed.assignment.id,
                     do: {:error, %{code: :unavailable}},
                     else: {:ok, [%{"id" => "sample-legacy"}]}
                 end
               )

      assert updated.id == existing.id
      assert updated.source_assignment_count == 2
      assert updated.metadata["source_assignment_models"][failed.assignment.id] == %{}

      assert updated.metadata["source_assignment_models"][healthy.assignment.id]["id"] ==
               "sample-legacy"

      assert updated.metadata["source_assignment_missing_sync_run_ids"] == %{}
      assert [%{"reason" => "model catalog sync failed"}] = run.stats["failed_assignments"]
    end
  end

  test "malformed per-source model metadata is replaced with an empty preserved source" do
    pool = pool_fixture()
    absent = source(pool)
    source(pool)

    model_fixture(pool, %{
      exposed_model_id: "sample-legacy",
      metadata: %{
        "source_assignment_ids" => [absent.assignment.id],
        "source_assignment_models" => %{absent.assignment.id => "invalid"}
      }
    })

    assert {:ok, %{models: [model], sync_run: run}} =
             Sync.sync_pool_catalog(pool,
               fetcher: fn source ->
                 {:ok,
                  if(source.assignment.id == absent.assignment.id,
                    do: [],
                    else: [%{"id" => "sample-legacy"}]
                  )}
               end
             )

    assert model.metadata["source_assignment_models"][absent.assignment.id] == %{}

    assert model.metadata["source_assignment_missing_sync_run_ids"] == %{
             absent.assignment.id => run.id
           }
  end

  defp count(pool),
    do: Repo.aggregate(from(model in Model, where: model.pool_id == ^pool.id), :count)

  defp source(pool) do
    source = upstream_assignment_fixture(pool)

    assert {:ok, _} =
             Upstreams.store_encrypted_secret(source.identity, %{
               secret_kind: "access_token",
               plaintext: "synthetic-catalog-token"
             })

    source
  end
end
