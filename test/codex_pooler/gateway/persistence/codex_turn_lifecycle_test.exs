defmodule CodexPooler.Gateway.Persistence.CodexTurnLifecycleTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.{CodexTurn, SessionContinuity}
  alias CodexPooler.Gateway.Persistence.SessionContinuity.TurnLifecycle
  alias CodexPooler.Gateway.Websocket

  setup do
    %{pool: pool, api_key: api_key} = active_api_key_fixture()
    auth = %{pool: pool, api_key: api_key}

    {:ok, session} =
      Websocket.start_codex_session(auth, %{accepted_turn_state: Ecto.UUID.generate()})

    request = request_fixture(auth, %{status: "in_progress", completed_at: nil})

    {:ok, turn} =
      SessionContinuity.start_codex_turn(session, request, RequestOptions.for_websocket(%{}))

    %{request: request, turn: turn}
  end

  test "persisted in-progress turns become terminal and cannot be finalized twice", %{
    request: request,
    turn: turn
  } do
    assert CodexTurn.in_progress?(Repo.reload!(turn))
    assert CodexTurn.in_progress?("in_progress")

    result = {:ok, %{request: request}}
    assert ^result = SessionContinuity.complete_codex_turn(result, "failed", :upstream_timeout)
    completed = Repo.reload!(turn)
    refute CodexTurn.in_progress?(completed)
    assert completed.status == "failed"
    assert completed.error_code == "upstream_timeout"
    assert %DateTime{} = completed.completed_at

    assert ^result = SessionContinuity.complete_codex_turn(result, "succeeded", nil)
    assert Repo.reload!(turn) == completed
  end

  test "terminal, absent and unknown statuses are never in progress" do
    for status <- ["succeeded", "failed", "interrupted", nil, "unknown"] do
      refute CodexTurn.in_progress?(status)
      refute CodexTurn.in_progress?(%CodexTurn{status: status})
    end
  end

  test "failed lifecycle results leave an in-progress turn untouched", %{turn: turn} do
    result = {:error, :reservation_failed}
    assert ^result = SessionContinuity.complete_codex_turn(result, "failed", :upstream_timeout)
    assert Repo.reload!(turn) == turn
  end

  test "legacy visibility is idempotent and malformed ownership cannot authorize output", %{
    request: request,
    turn: turn
  } do
    assert :ok = TurnLifecycle.mark_codex_turn_visible(request)
    visible = Repo.reload!(turn)
    assert %DateTime{} = visible.first_visible_output_at
    assert :ok = TurnLifecycle.mark_codex_turn_visible(request)
    assert Repo.reload!(turn) == visible

    for invalid <- [
          nil,
          %{},
          %{id: Ecto.UUID.generate(), request_id: request.id, replay_generation: "0"}
        ] do
      assert {:error, :stale_generation} =
               TurnLifecycle.authorize_codex_turn_visibility(request, invalid)

      assert Repo.reload!(turn) == visible
    end

    assert :ok = TurnLifecycle.mark_codex_turn_visible(nil)
    assert Repo.reload!(turn) == visible
  end
end
