defmodule CodexPooler.Upstreams.Quota.Windows.AttributesTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Upstreams.Quota.Windows
  alias CodexPooler.Upstreams.Quota.Windows.Attributes

  test "metadata accepts legacy key shapes and ignores absent or non-list collections" do
    for metadata <- [nil, [], "invalid", %{}, %{"quota_windows" => nil}, %{quota_windows: %{}}] do
      assert Windows.quota_windows_from_metadata(metadata) == []
    end

    for key <- [:quota_windows, "quota_windows"] do
      assert [%{quota_key: "account", window_kind: "primary"}] =
               Windows.quota_windows_from_metadata(%{key => [%{"window_kind" => "primary"}]})
    end

    assert [%{window_kind: "secondary"}] =
             Windows.quota_windows_from_metadata(%{
               :quota_windows => [%{window_kind: "primary"}],
               "quota_windows" => [%{"window_kind" => "secondary"}]
             })
  end

  test "normalizes percentages without rounding or treating missing values as zero" do
    for {input, expected} <- [
          {0, "0"},
          {100, "100"},
          {12.5, "12.5"},
          {" 12.500 ", "12.500"},
          {"1e1", "10"},
          {Decimal.new("99.999"), "99.999"}
        ] do
      assert %{used_percent: actual} = Attributes.normalize(%{used_percent: input})
      assert Decimal.equal?(actual, Decimal.new(expected))
    end

    for value <- [nil, "", "12percent", "unknown", true, false, [], %{}] do
      assert %{used_percent: nil} = Attributes.normalize(%{"used_percent" => value})
    end
  end

  test "normalizes timestamp offsets and rejects malformed timestamp shapes" do
    expected = ~U[2026-09-01 10:00:00.123456Z]

    for key <- [:reset_at, :last_sync_at, :observed_at] do
      for value <- [expected, "2026-09-01T12:00:00.123456+02:00"] do
        assert Attributes.normalize(%{key => value})[key] == expected
      end

      for value <- [nil, "not-a-date", "2026-09-01", 1_788_256_800, %{}] do
        assert Attributes.normalize(%{key => value})[key] == nil
      end
    end
  end

  test "preserves zero limits and defaults only optional absent fields" do
    assert %{active_limit: 0, credits: 0, used_percent: used} =
             Attributes.normalize(%{"active_limit" => 0, "credits" => 0, "used_percent" => 0})

    assert Decimal.equal?(used, Decimal.new(0))

    assert %{
             quota_key: "account",
             source: "local_reconciliation",
             freshness_state: "fresh",
             metadata: %{}
           } = Attributes.normalize(%{})

    assert Attributes.normalize(nil) == %{}
  end
end
