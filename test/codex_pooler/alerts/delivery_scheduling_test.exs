defmodule CodexPooler.Alerts.Delivery.DeliverySchedulingTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Alerts.Delivery.{AttemptLifecycle, DeliveryScheduling}
  alias CodexPooler.Alerts.Schemas.AlertRuleChannel

  @now ~U[2026-09-07 12:00:00.000000Z]

  setup do
    pool = pool_fixture()
    incident = alert_incident_fixture(pool: pool)
    channel = alert_channel_fixture()
    %{pool: pool, incident: incident, channel: channel}
  end

  test "shared channels use the longest active rule cooldown once", context do
    link_rule(context, cooldown_minutes: 5)
    link_rule(context, cooldown_minutes: 30)
    link_rule(context, cooldown_minutes: 90, state: "disabled", disabled_at: @now)

    assert [%{channel_id: id, cooldown_minutes: 30}] = due(context)
    assert id == context.channel.id
  end

  test "disabled rules do not suppress delivery after the active rule cooldown", context do
    link_rule(context, cooldown_minutes: 5)
    link_rule(context, cooldown_minutes: 90, state: "disabled", disabled_at: @now)
    sent_at = DateTime.add(@now, -10 * 60, :second)

    assert {:ok, _} =
             AttemptLifecycle.insert_sent_attempt(
               context.incident,
               context.channel,
               1,
               sent_at,
               %{}
             )

    assert [_] = due(context)

    assert :ok =
             AttemptLifecycle.ensure_not_suppressed(
               context.incident,
               context.channel,
               @now,
               "email"
             )
  end

  test "cooldown includes its exact boundary and expires one microsecond later", context do
    link_rule(context, cooldown_minutes: 5)
    sent_at = DateTime.add(@now, -300, :second)

    assert {:ok, _} =
             AttemptLifecycle.insert_sent_attempt(
               context.incident,
               context.channel,
               1,
               sent_at,
               %{}
             )

    assert [] = due(context)

    assert [_] =
             DeliveryScheduling.list_incident_delivery_channels_due(context.incident,
               now: DateTime.add(@now, 1, :microsecond)
             )
  end

  test "pending and failed attempts do not trigger cooldown", context do
    link_rule(context, cooldown_minutes: 5)

    assert {:ok, _} =
             AttemptLifecycle.insert_pending_attempt(
               context.incident,
               context.channel,
               1,
               @now,
               %{}
             )

    assert {:ok, _} =
             AttemptLifecycle.record_failed_attempt(
               context.incident.id,
               context.channel.id,
               2,
               @now,
               "email",
               "delivery_failed",
               "delivery failed"
             )

    assert [_] = due(context)
  end

  test "attempt numbering continues persisted history and respects retry number", context do
    %{incident: incident, channel: channel} = context
    assert 1 = DeliveryScheduling.next_delivery_attempt_number(incident.id, channel.id, 1)
    assert {:ok, _} = AttemptLifecycle.insert_pending_attempt(incident, channel, 4, @now, %{})
    assert 5 = DeliveryScheduling.next_delivery_attempt_number(incident.id, channel.id, 2)
    assert 12 = DeliveryScheduling.next_delivery_attempt_number(incident.id, channel.id, 12)

    assert 1 =
             DeliveryScheduling.next_delivery_attempt_number(incident.id, Ecto.UUID.generate(), 1)

    assert 3 = DeliveryScheduling.next_delivery_attempt_number(nil, nil, 3)
    assert 1 = DeliveryScheduling.next_delivery_attempt_number(nil, nil, 0)
  end

  test "disabled channels and unlinked incidents have no due deliveries", context do
    channel = alert_channel_fixture(state: "disabled", disabled_at: @now)
    link_rule(%{context | channel: channel}, cooldown_minutes: 5)
    assert [] = due(context)
    assert [] = DeliveryScheduling.list_incident_delivery_channels_due(Ecto.UUID.generate())
    assert [] = DeliveryScheduling.list_incident_delivery_channels_due(nil)
  end

  defp due(context),
    do: DeliveryScheduling.list_incident_delivery_channels_due(context.incident, now: @now)

  defp link_rule(context, attrs) do
    rule = alert_rule_fixture(context.pool, attrs)
    alert_incident_target_fixture(context.incident, rule, context.pool)

    %AlertRuleChannel{}
    |> AlertRuleChannel.changeset(%{
      alert_rule_id: rule.id,
      alert_channel_id: context.channel.id,
      created_at: @now
    })
    |> Repo.insert!()
  end
end
