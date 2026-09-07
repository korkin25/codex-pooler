defmodule CodexPooler.Jobs.RuntimeStateCleanupWorkerTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Files.FileRecord
  alias CodexPooler.Jobs.RuntimeStateCleanupWorker

  test "worker executes cleanup at the supplied offset-aware timestamp and is idempotent" do
    now = ~U[2026-09-07 12:00:00.123456Z]
    expired = file_at(now)
    future = file_at(DateTime.add(now, 1, :microsecond))
    args = %{"now" => "2026-09-07T14:00:00.123456+02:00"}

    assert :ok = perform_job(RuntimeStateCleanupWorker, args)
    assert Repo.reload!(expired).status == "abandoned"
    assert Repo.reload!(future).status == "pending_upload"
    after_first = Repo.reload!(expired)
    assert :ok = perform_job(RuntimeStateCleanupWorker, args)
    assert Repo.reload!(expired) == after_first
  end

  test "absent or malformed clock arguments use current time rather than skip cleanup" do
    for args <- [%{}, %{"now" => "invalid"}, %{"now" => 42}] do
      expired = file_at(DateTime.add(DateTime.utc_now(), -60, :second))
      future = file_at(DateTime.add(DateTime.utc_now(), 3600, :second))
      assert :ok = perform_job(RuntimeStateCleanupWorker, args)
      assert Repo.reload!(expired).status == "abandoned"
      assert Repo.reload!(future).status == "pending_upload"
    end
  end

  test "retry backoff is bounded by the configured attempts and timeout" do
    assert RuntimeStateCleanupWorker.timeout(%Oban.Job{}) == :timer.minutes(5)

    for attempt <- 1..3 do
      assert RuntimeStateCleanupWorker.backoff(%Oban.Job{attempt: attempt}) == attempt * 30
    end

    assert RuntimeStateCleanupWorker.new(%{}).changes.max_attempts == 3
  end

  defp file_at(expires_at) do
    %{pool: pool, api_key: key} = active_api_key_fixture()
    now = DateTime.add(expires_at, -3600, :second)

    %FileRecord{}
    |> FileRecord.changeset(%{
      pool_id: pool.id,
      api_key_id: key.id,
      file_id: "file-#{System.unique_integer([:positive])}",
      purpose: "user_data",
      filename: "sample.txt",
      byte_size: 1,
      status: "pending_upload",
      finalize_status: "pending",
      expires_at: expires_at,
      metadata: %{},
      created_at: now,
      updated_at: now
    })
    |> Repo.insert!()
  end
end
