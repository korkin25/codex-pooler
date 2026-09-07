defmodule CodexPooler.Files.FileRecordTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Files.{FileRecord, FileState}

  setup do
    %{pool: pool, api_key: api_key} = active_api_key_fixture()
    now = DateTime.utc_now()

    attrs = %{
      pool_id: pool.id,
      api_key_id: api_key.id,
      file_id: "file-#{System.unique_integer([:positive])}",
      purpose: "user_data",
      filename: "sample.txt",
      byte_size: 0,
      status: FileRecord.pending_upload_status(),
      finalize_status: FileRecord.pending_finalize_status(),
      expires_at: DateTime.add(now, 60, :second),
      metadata: %{},
      created_at: now,
      updated_at: now
    }

    %{attrs: attrs, now: now, pool: pool}
  end

  test "all declared states persist and reload through the database", %{attrs: attrs} do
    for status <- FileRecord.statuses(), finalize_status <- FileRecord.finalize_statuses() do
      file =
        insert_record(
          Map.merge(attrs, %{
            file_id: "file-#{System.unique_integer([:positive])}",
            status: status,
            finalize_status: finalize_status
          })
        )

      reloaded = Repo.get!(FileRecord, file.id)
      assert reloaded.status == status
      assert reloaded.finalize_status == finalize_status
      assert reloaded.byte_size == 0
      assert reloaded.metadata == %{}
    end
  end

  test "invalid state and size values are rejected before insertion", %{attrs: attrs} do
    for {field, value, message} <- [
          {:status, "unknown", "is invalid"},
          {:finalize_status, "unknown", "is invalid"},
          {:byte_size, -1, "must be greater than or equal to 0"},
          {:byte_size, "invalid", "is invalid"}
        ] do
      assert {:error, changeset} =
               %FileRecord{}
               |> FileRecord.changeset(Map.put(attrs, field, value))
               |> Repo.insert()

      assert message in Map.fetch!(errors_on(changeset), field)
    end

    assert Repo.aggregate(FileRecord, :count) == 0
  end

  test "required ownership and metadata fields cannot be omitted", %{attrs: attrs} do
    for field <- Map.keys(attrs) do
      changeset = FileRecord.changeset(%FileRecord{}, Map.delete(attrs, field))
      assert "can't be blank" in Map.fetch!(errors_on(changeset), field)
    end
  end

  test "successful upload persists completion timestamps and preserves metadata", %{
    attrs: attrs,
    now: now
  } do
    file = insert_record(attrs)
    completed_at = DateTime.add(now, 1, :second)

    FileState.complete_upload!(file, completed_at)
    reloaded = Repo.get!(FileRecord, file.id)

    assert reloaded.status == FileRecord.uploaded_status()
    assert reloaded.finalize_status == FileRecord.succeeded_finalize_status()
    assert reloaded.uploaded_at == completed_at
    assert reloaded.updated_at == completed_at
    assert reloaded.created_at == now
    assert reloaded.expires_at == attrs.expires_at
    assert reloaded.metadata == %{}
    assert FileState.classify(reloaded, completed_at) == :uploaded

    FileState.expire!(reloaded, attrs.expires_at)
    expired = Repo.get!(FileRecord, file.id)
    assert expired.status == FileRecord.expired_status()
    assert expired.deleted_at == attrs.expires_at
    assert expired.updated_at == attrs.expires_at
    assert expired.uploaded_at == completed_at
    assert expired.finalize_status == FileRecord.succeeded_finalize_status()
  end

  test "failed finalization persists a terminal non-uploadable state", %{attrs: attrs, now: now} do
    file = insert_record(attrs)
    failed_at = DateTime.add(now, 1, :second)

    FileState.fail_finalize!(file, failed_at)
    reloaded = Repo.get!(FileRecord, file.id)

    assert reloaded.status == FileRecord.abandoned_status()
    assert reloaded.finalize_status == FileRecord.failed_finalize_status()
    assert reloaded.updated_at == failed_at
    assert reloaded.uploaded_at == nil
    assert FileState.classify(reloaded, failed_at) == :not_uploadable
  end

  test "classification respects upstream affinity and expiration at the exact deadline", %{
    attrs: attrs,
    now: now,
    pool: pool
  } do
    local = insert_record(attrs)
    assert FileState.classify(nil, now) == :missing
    assert FileState.classify(local, now) == :local_pending

    %{assignment: assignment} = upstream_assignment_fixture(pool)

    upstream =
      local
      |> Ecto.Changeset.change(pool_upstream_assignment_id: assignment.id)
      |> Repo.update!()

    assert FileState.classify(upstream, now) == :upstream_pending
    refute FileState.expired?(upstream, DateTime.add(attrs.expires_at, -1, :microsecond))
    assert FileState.expired?(upstream, attrs.expires_at)
    assert FileState.classify(upstream, attrs.expires_at) == :expired

    for status <- [FileRecord.deleted_status(), FileRecord.abandoned_status()] do
      assert FileState.classify(%{upstream | status: status}, now) == :not_uploadable
    end

    assert FileState.classify(%{upstream | status: FileRecord.expired_status()}, now) == :expired

    assert FileState.classify(
             %{upstream | status: FileRecord.uploaded_status()},
             attrs.expires_at
           ) ==
             :expired
  end

  defp insert_record(attrs) do
    %FileRecord{}
    |> FileRecord.changeset(attrs)
    |> Repo.insert!()
  end
end
