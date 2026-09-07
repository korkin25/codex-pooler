defmodule CodexPooler.Catalog.AssignmentModelSummariesTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Catalog.AssignmentModelSummaries

  import CodexPooler.PoolerFixtures

  test "fails closed for malformed authorization entries even beside an authorized tuple" do
    pool = pool_fixture()
    %{assignment: assignment} = upstream_assignment_fixture(pool)
    model_fixture(pool, %{metadata: %{"source_assignment_models" => %{assignment.id => %{}}}})
    authorized = {pool.id, assignment.id}

    for invalid <- [
          nil,
          %{},
          [authorized, nil],
          [authorized, {pool.id, "bad"}],
          [{nil, assignment.id}]
        ] do
      assert AssignmentModelSummaries.list(invalid) == []
    end

    assert [%{assignment_id: id}] = AssignmentModelSummaries.list([authorized, authorized])
    assert id == assignment.id
  end

  test "ignores malformed sources and honors explicit uncertain capabilities over nested claims" do
    pool = pool_fixture()
    %{assignment: assignment} = upstream_assignment_fixture(pool)
    %{assignment: malformed} = upstream_assignment_fixture(pool)

    model_fixture(pool, %{
      metadata: %{
        "source_assignment_models" => %{
          assignment.id => %{
            "supports_tools" => nil,
            "capabilities" => %{"tools" => true, "responses" => false}
          },
          malformed.id => []
        },
        "source_assignment_missing_sync_run_ids" => []
      }
    })

    assert [summary] =
             AssignmentModelSummaries.list([{pool.id, assignment.id}, {pool.id, malformed.id}])

    assert summary.provenance == :observed

    assert summary.capabilities == %{
             responses: false,
             streaming: :unknown,
             tools: :unknown,
             reasoning: :unknown
           }

    assert summary.model_info.catalog_updated_at
  end
end
