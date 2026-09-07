defmodule CodexPooler.Upstreams.Lifecycle.InternalLifecycleTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Upstreams.Lifecycle.InternalLifecycle
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}

  setup do
    %{pool: pool_fixture()}
  end

  test "pending creation binds trusted ownership and ignores unverified plan metadata", %{
    pool: pool
  } do
    assert {:ok, %{identity: identity, assignment: assignment}} =
             InternalLifecycle.create_pending_pool_account(
               pool,
               Map.merge(identity_attrs(), %{plan_family: "pro", plan_label: "Pro"}),
               %{pool_id: Ecto.UUID.generate(), upstream_identity_id: Ecto.UUID.generate()}
             )

    assert identity.status == "pending"
    assert identity.plan_family == nil
    assert identity.plan_label == nil
    assert assignment.status == "pending"
    assert assignment.health_status == "unknown"
    assert assignment.pool_id == pool.id
    assert assignment.upstream_identity_id == identity.id
    assert Repo.get!(UpstreamIdentity, identity.id) == identity
    assert Repo.get!(PoolUpstreamAssignment, assignment.id) == assignment
  end

  test "invalid pending identity stops before assignment creation", %{pool: pool} do
    before_count = Repo.aggregate(PoolUpstreamAssignment, :count)

    assert {:error, changeset} =
             InternalLifecycle.create_pending_pool_account(
               pool,
               identity_attrs(%{account_label: ""}),
               %{}
             )

    assert "can't be blank" in errors_on(changeset).account_label
    assert Repo.aggregate(PoolUpstreamAssignment, :count) == before_count
  end

  test "caller transaction rolls back pending identity when assignment validation fails", %{
    pool: pool
  } do
    before_count = Repo.aggregate(UpstreamIdentity, :count)

    assert {:error, changeset} =
             in_transaction(fn ->
               InternalLifecycle.create_pending_pool_account(pool, identity_attrs(), %{
                 status: "invalid"
               })
             end)

    assert "is invalid" in errors_on(changeset).status
    assert Repo.aggregate(UpstreamIdentity, :count) == before_count
  end

  test "pending refresh persists both labels while retaining verified plan fields", %{pool: pool} do
    %{identity: identity, assignment: assignment} = pending_account(pool)

    assert {:ok, refreshed} =
             InternalLifecycle.update_pending_pool_account(
               identity,
               assignment,
               %{account_label: "Refreshed account", plan_family: "pro", plan_label: "Pro"},
               %{assignment_label: "Refreshed assignment"}
             )

    assert Repo.get!(UpstreamIdentity, identity.id).account_label == "Refreshed account"

    assert Repo.get!(PoolUpstreamAssignment, assignment.id).assignment_label ==
             "Refreshed assignment"

    assert refreshed.identity.plan_family == nil
    assert refreshed.identity.status == "pending"
    assert refreshed.assignment.status == "pending"
  end

  test "pending refresh rejects invalid identity before updating assignment", %{pool: pool} do
    %{identity: identity, assignment: assignment} = pending_account(pool)

    assert {:error, changeset} =
             InternalLifecycle.update_pending_pool_account(
               identity,
               assignment,
               %{account_label: ""},
               %{assignment_label: "Changed"}
             )

    assert "can't be blank" in errors_on(changeset).account_label
    assert Repo.get!(PoolUpstreamAssignment, assignment.id) == assignment
  end

  test "caller transaction rolls back pending refresh when assignment update fails", %{pool: pool} do
    %{identity: identity, assignment: assignment} = pending_account(pool)

    assert {:error, changeset} =
             in_transaction(fn ->
               InternalLifecycle.update_pending_pool_account(
                 identity,
                 assignment,
                 %{account_label: "Changed"},
                 %{status: "invalid"}
               )
             end)

    assert "is invalid" in errors_on(changeset).status
    assert Repo.get!(UpstreamIdentity, identity.id) == identity
    assert Repo.get!(PoolUpstreamAssignment, assignment.id) == assignment
  end

  test "verified activation persists plan evidence and clears disabled state", %{pool: pool} do
    %{identity: identity, assignment: assignment} = pending_account(pool)
    timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    identity = identity |> change(status: "disabled", disabled_at: timestamp) |> Repo.update!()

    assignment =
      assignment |> change(status: "disabled", disabled_at: timestamp) |> Repo.update!()

    assert {:ok, activated} =
             InternalLifecycle.activate_verified_pool_account(
               identity,
               assignment,
               %{plan_family: "pro", plan_label: "Pro", auth_verified_at: timestamp},
               %{}
             )

    assert activated.identity.status == "active"
    assert activated.identity.plan_family == "pro"
    assert activated.identity.auth_verified_at == timestamp
    assert activated.identity.disabled_at == nil
    assert activated.assignment.status == "active"
    assert activated.assignment.health_status == "active"
    assert activated.assignment.eligibility_status == "eligible"
    assert activated.assignment.disabled_at == nil
    assert Repo.get!(UpstreamIdentity, identity.id) == activated.identity
    assert Repo.get!(PoolUpstreamAssignment, assignment.id) == activated.assignment
  end

  test "verified activation stops on invalid identity without activating assignment", %{
    pool: pool
  } do
    %{identity: identity, assignment: assignment} = pending_account(pool)

    assert {:error, changeset} =
             InternalLifecycle.activate_verified_pool_account(
               identity,
               assignment,
               %{plan_family: "!"},
               %{}
             )

    assert "has invalid format" in errors_on(changeset).plan_family
    assert Repo.get!(PoolUpstreamAssignment, assignment.id) == assignment
  end

  test "ensuring an active assignment persists routing state for the supplied identity", %{
    pool: pool
  } do
    identity = active_upstream_identity_fixture()

    assert {:ok, assignment} =
             InternalLifecycle.ensure_active_pool_assignment(pool, identity, %{})

    assert assignment.upstream_identity_id == identity.id
    assert assignment.pool_id == pool.id
    assert assignment.status == "active"
    assert assignment.health_status == "active"
    assert assignment.eligibility_status == "eligible"
    assert Repo.get!(PoolUpstreamAssignment, assignment.id) == assignment
  end

  test "ensuring an assignment propagates missing identity without inserting rows", %{pool: pool} do
    identity = %UpstreamIdentity{id: Ecto.UUID.generate()}
    before_count = Repo.aggregate(PoolUpstreamAssignment, :count)

    assert {:error, %{code: :upstream_identity_not_found}} =
             InternalLifecycle.ensure_active_pool_assignment(pool, identity, %{})

    assert Repo.aggregate(PoolUpstreamAssignment, :count) == before_count
  end

  defp pending_account(pool) do
    {:ok, account} = InternalLifecycle.create_pending_pool_account(pool, identity_attrs(), %{})
    account
  end

  defp identity_attrs(overrides \\ %{}),
    do:
      Map.merge(
        %{account_label: "Pending sample account", onboarding_method: "invite"},
        overrides
      )

  defp in_transaction(fun) do
    Repo.transaction(fn ->
      case fun.() do
        {:ok, value} -> value
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end
end
