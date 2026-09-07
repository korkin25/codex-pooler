defmodule CodexPooler.Quotas.ResetTimesTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Quotas.Evidence.CodexParsers
  alias CodexPooler.Quotas.Evidence.CodexParsers.ResetTimes
  alias CodexPooler.Quotas.Evidence.CodexParsers.WindowKinds

  @observed_at ~U[2026-09-07 12:00:00.123456Z]
  @reset_at ~U[2026-09-07 13:00:00.123456Z]

  test "out-of-calendar relative resets remain unknown at the event boundary" do
    for seconds <- [1_000_000_000_000_000, "1000000000000000", 1.0e100] do
      assert [evidence] =
               CodexParsers.parse_codex_rate_limit_event(event(seconds), @observed_at)

      assert evidence.reset_at == nil
      assert evidence.source_precision == "inferred"
    end
  end

  test "absolute reset aliases accept datetimes, epoch values and offset timestamps" do
    for key <- ["reset_at", "resets_at", :reset_at, :resets_at] do
      assert ResetTimes.reset_at_from(%{key => @reset_at}, nil) == @reset_at

      for value <- [DateTime.to_unix(@reset_at), " 1788786000 "] do
        assert ResetTimes.reset_at_from(%{key => value}, nil) ==
                 DateTime.truncate(@reset_at, :second)
      end

      assert ResetTimes.reset_at_from(%{key => "2026-09-07T15:00:00.123456+02:00"}, nil) ==
               @reset_at
    end
  end

  test "relative and absolute epoch resets agree at the supported calendar boundary" do
    last_second = ~U[9999-12-31 23:59:59.123456Z]
    seconds = DateTime.diff(last_second, @observed_at, :second)

    assert ResetTimes.reset_at_from(%{"reset_after_seconds" => seconds}, @observed_at) ==
             last_second

    assert ResetTimes.reset_at_from(%{"reset_after_seconds" => seconds + 1}, @observed_at) == nil

    assert ResetTimes.reset_at_from(%{"reset_at" => DateTime.to_unix(last_second) + 1}, nil) ==
             nil
  end

  test "explicit reset takes precedence over relative duration and marks evidence observed" do
    attrs = %{"reset_at" => @reset_at, "reset_after_seconds" => 10}
    assert ResetTimes.reset_at_from(attrs, @observed_at) == @reset_at
    assert ResetTimes.reset_source_precision(attrs, @reset_at) == "observed"
    assert ResetTimes.reset_source_precision(attrs, nil) == "inferred"
  end

  test "relative resets preserve microseconds and support numeric provider representations" do
    for key <- ["reset_after_seconds", :reset_after_seconds], value <- [3600, " 3600 ", 3600.9] do
      attrs = %{key => value}
      assert ResetTimes.reset_at_from(attrs, @observed_at) == @reset_at
      assert ResetTimes.explicit_reset_at_from(attrs) == nil
      assert ResetTimes.reset_source_precision(attrs, @reset_at) == "inferred"
      assert ResetTimes.reset_at_from(attrs, nil) == nil
    end

    assert ResetTimes.reset_at_from(%{"reset_after_seconds" => 0}, @observed_at) == @observed_at
  end

  test "malformed absolute resets can fall back to valid relative duration" do
    for value <- [nil, false, %{}, [], 0, -1, 1.2, "", "garbage", "123x", 1_000_000_000_000_000] do
      attrs = %{"reset_at" => value, "reset_after_seconds" => 3600}
      assert ResetTimes.reset_at_from(attrs, @observed_at) == @reset_at
      assert ResetTimes.explicit_reset_at_from(attrs) == nil
      assert ResetTimes.reset_source_precision(attrs, @reset_at) == "inferred"
    end
  end

  test "missing or malformed relative duration leaves the reset unknown" do
    for value <- [nil, false, %{}, [], -1, -0.5, "-1", "1.2", "1sec", ""] do
      assert ResetTimes.reset_at_from(%{"reset_after_seconds" => value}, @observed_at) == nil
    end

    assert ResetTimes.reset_at_from(%{}, @observed_at) == nil
  end

  test "weekly primary normalization changes only the weekly primary identity" do
    assert WindowKinds.normalize_window_kind("primary", 10_080) == "secondary"

    for {kind, minutes} <- [
          {"primary", 300},
          {"primary", nil},
          {"secondary", 10_080},
          {"custom", 10_080}
        ] do
      assert WindowKinds.normalize_window_kind(kind, minutes) == kind
    end
  end

  defp event(seconds) do
    %{
      "type" => "codex.rate_limits",
      "rate_limits" => %{
        "primary" => %{
          "window_minutes" => 300,
          "used_percent" => 20,
          "reset_after_seconds" => seconds
        }
      }
    }
  end
end
