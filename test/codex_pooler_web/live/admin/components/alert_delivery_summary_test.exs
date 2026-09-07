defmodule CodexPoolerWeb.Admin.AlertDeliverySummaryTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias CodexPoolerWeb.Admin.AlertsPageComponents.Incidents

  test "lifetime delivery sequence does not display a per-job retry denominator" do
    incident = %{
      id: "sample",
      delivery_summary: %{
        label: "6 attempts",
        attempts: [
          %{
            id: "attempt",
            channel_label: "Sample",
            status: "sent",
            status_label: "Sent",
            attempt_number: 6,
            max_attempts: 5,
            attempted_at: nil,
            completed_at: nil,
            details: []
          }
        ]
      }
    }

    html =
      render_component(&Incidents.incident_delivery_summary/1,
        incident: incident,
        prefix: "sample"
      )

    assert html =~ "Delivery attempt 6"
    refute html =~ "6/5"
  end
end
