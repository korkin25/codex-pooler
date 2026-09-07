defmodule CodexPooler.Catalog.ModelSelectorStateTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Catalog.Model
  alias CodexPooler.Catalog.ModelSelectorState

  test "normalizes legacy aliases and excludes malformed and duplicate selections" do
    state =
      ModelSelectorState.build(
        %{
          "allowed_models_mode" => "none",
          "allowed_models" => [" Sample ", "sample", nil, "bad model"],
          "manual_models" => " CUSTOM, custom\nsecond "
        },
        %{status: :empty, reason: nil},
        []
      )

    assert state.mode == :deny_all_models
    assert state.selected_identifiers == ["sample"]
    assert state.manual_identifiers == ["custom", "second"]
    assert [%{status: :unavailable}] = state.selected_unavailable_chips
    assert Enum.all?(state.manual_chips, &(&1.status == :manual_unverified))
  end

  test "returns structured errors for invalid text inputs and deduplicates valid identifiers" do
    for invalid <- [nil, 12, %{}, "sample\0model"] do
      assert {:error, %{code: :invalid_model_identifier}} =
               ModelSelectorState.validate_manual_model_identifier(invalid)
    end

    assert {:ok, ["sample", "other"]} =
             ModelSelectorState.validate_manual_model_identifiers([" Sample ", "sample", "OTHER"])

    assert {:ok, []} = ModelSelectorState.validate_manual_model_identifiers(nil)
  end

  test "failed catalog without a reason provides an actionable fallback" do
    state = ModelSelectorState.build(%{}, %{status: :failed, reason: nil}, [])
    assert state.catalog.message == "Model catalog sync failed"
    assert state.catalog.requires_acknowledgement?
    assert [%{code: :failed, message: "Model catalog sync failed"}] = state.warnings
  end

  test "malformed persisted source ids and non-list selections do not create phantom options" do
    for metadata <- [
          nil,
          %{"source_assignment_ids" => "not-a-list"},
          %{"source_assignment_ids" => %{}}
        ] do
      model = %Model{exposed_model_id: "sample", display_name: "Sample", metadata: metadata}

      state =
        ModelSelectorState.build(
          %{selected_model_identifiers: %{}, manual_model_identifiers: 42},
          %{status: :synced, reason: nil},
          [model]
        )

      assert state.selected_identifiers == []
      assert state.manual_identifiers == []
      assert [%{identifier: "sample", source_assignment_ids: []}] = state.options
      assert ModelSelectorState.validate_manual_model_identifiers(%{}) == {:ok, []}
    end
  end
end
