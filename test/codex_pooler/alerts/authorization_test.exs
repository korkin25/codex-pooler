defmodule CodexPooler.Alerts.AuthorizationTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Alerts.Authorization
  alias CodexPooler.Pools.OperatorPoolAssignment

  test "pool filters follow persisted grants and revoke an already loaded scope" do
    %{user: owner} = bootstrap_owner_fixture()
    %{user: admin} = operator_fixture(owner)
    allowed = pool_fixture()
    other = pool_fixture()
    assignment = operator_pool_assignment_fixture(admin, allowed)
    scope = Scope.for_user(admin)

    assert {:ok, [allowed_id]} = Authorization.authorized_pool_filter(scope, nil)
    assert allowed_id == allowed.id
    assert {:ok, [^allowed_id]} = Authorization.authorized_pool_filter(scope, allowed.id)
    assert {:error, _} = Authorization.authorized_pool_filter(scope, other.id)
    assert {:ok, user_id} = Authorization.scope_user_id(scope)
    assert user_id == admin.id

    assignment
    |> Ecto.Changeset.change(status: "revoked", revoked_at: DateTime.utc_now())
    |> Repo.update!()

    assert Repo.get!(OperatorPoolAssignment, assignment.id).status == "revoked"
    assert {:ok, []} = Authorization.authorized_pool_filter(scope, nil)
    assert {:error, _} = Authorization.authorize_pool_operation(scope, allowed.id)
  end

  test "invalid scopes and pool selectors return explicit errors" do
    for scope <- [nil, %{}] do
      assert {:error, %{code: :invalid_request}} = Authorization.list_manageable_pools(scope)
      assert {:error, %{code: :invalid_request}} = Authorization.scope_user_id(scope)
    end

    assert {:error, %{code: :invalid_request}} = Authorization.scope_user_id(%Scope{})

    for id <- [nil, 42, %{}, []] do
      assert {:error, %{code: :invalid_request}} = Authorization.authorize_pool_operation(nil, id)
      assert {:error, %{code: :invalid_request}} = Authorization.authorized_pool_filter(nil, id)
    end
  end
end
