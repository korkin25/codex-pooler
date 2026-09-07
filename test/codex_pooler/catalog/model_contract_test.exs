defmodule CodexPooler.Catalog.ModelContractTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Catalog.Model
  alias CodexPooler.Repo

  import CodexPooler.PoolerFixtures

  test "rejects cleared required text without crashing or modifying the stored model" do
    model = model_fixture()

    for field <- [:upstream_model_id, :exposed_model_id, :display_name], value <- [nil, " "] do
      assert {:error, changeset} = model |> Model.changeset(%{field => value}) |> Repo.update()
      assert "can't be blank" in errors_on(changeset)[field]
      assert Map.fetch!(Repo.get!(Model, model.id), field) == Map.fetch!(model, field)
    end
  end

  test "trims identifiers and enforces pool-scoped uniqueness through Postgres" do
    pool = pool_fixture()
    first = model_fixture(pool, %{exposed_model_id: "sample-first"})
    second = model_fixture(pool, %{exposed_model_id: "sample-second"})

    assert {:ok, updated} =
             first
             |> Model.changeset(%{display_name: " Sample ", upstream_model_id: " source "})
             |> Repo.update()

    assert updated.display_name == "Sample"
    assert updated.upstream_model_id == "source"

    assert {:error, changeset} =
             second |> Model.changeset(%{exposed_model_id: " sample-first "}) |> Repo.update()

    assert "has already been taken" in errors_on(changeset).exposed_model_id
  end

  test "rejects unknown status and negative source counts while accepting zero and false capabilities" do
    model = model_fixture()
    changeset = Model.changeset(model, %{status: "unknown", source_assignment_count: -1})
    assert "is invalid" in errors_on(changeset).status
    assert "must be greater than or equal to 0" in errors_on(changeset).source_assignment_count

    assert {:ok, updated} =
             model
             |> Model.changeset(%{source_assignment_count: 0, supports_tools: false})
             |> Repo.update()

    assert updated.source_assignment_count == 0
    refute updated.supports_tools
  end
end
