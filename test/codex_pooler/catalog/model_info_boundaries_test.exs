defmodule CodexPooler.Catalog.ModelInfoBoundariesTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Catalog.ModelInfo

  test "normalizes source ids and does not use fallback for missing selected assignments" do
    metadata = %{
      "source_assignment_models" => %{"a" => %{"description" => " selected "}, "b" => nil},
      "upstream_model" => %{"description" => "fallback"}
    }

    assert ModelInfo.from_metadata(metadata, [nil, " a ", "a", ""]).description == "selected"
    assert ModelInfo.from_metadata(metadata, ["missing"]) == ModelInfo.empty()
    assert ModelInfo.from_metadata(metadata, []).description == "selected"
    assert ModelInfo.from_metadata(nil, []) == ModelInfo.empty()
    assert ModelInfo.from_metadata(metadata, nil) == ModelInfo.empty()
    assert ModelInfo.from_sources(nil) == ModelInfo.empty()
    refute ModelInfo.present?(nil)
  end

  test "ignores malformed source facts and conservatively preserves unknown states" do
    sources = [
      nil,
      %{"description" => " ", "visibility" => "other", "supported_in_api" => "true"}
    ]

    assert ModelInfo.from_sources(sources) == ModelInfo.empty()

    info = ModelInfo.from_sources([%{"visibility" => " HIDE ", "supported_in_api" => false}, %{}])
    assert info.visibility == :unknown
    assert info.api_support == :unknown
  end

  test "bounds context profiles and deduplicates client versions without dropping opaque versions" do
    info =
      ModelInfo.from_sources([
        %{
          "context_window" => 1,
          "max_context_window" => 0,
          "effective_context_window_percent" => 0
        },
        %{
          "context_window" => 100,
          "max_context_window" => 50,
          "effective_context_window_percent" => 100
        },
        %{"context_window" => "100", "minimal_client_version" => " "},
        %{"minimal_client_version" => " preview "},
        %{"minimal_client_version" => "preview"},
        %{"minimal_client_version" => "0.10.0"},
        %{"minimal_client_version" => "0.2.0"}
      ])

    assert info.context_profiles == [
             %{
               raw_window: 1,
               usable_window: 1,
               raw_max_window: 1,
               usable_max_window: 1,
               effective_percent: 95
             },
             %{
               raw_window: 100,
               usable_window: 100,
               raw_max_window: 100,
               usable_max_window: 100,
               effective_percent: 100
             }
           ]

    assert info.minimal_client_versions == ["0.2.0", "0.10.0", "preview"]
  end

  test "merges conflicting and unknown projections and rejects malformed context profiles" do
    mixed =
      ModelInfo.from_sources([
        %{"description" => "a", "visibility" => "hide"},
        %{"description" => "b", "visibility" => "list"}
      ])

    invalid = Map.put(ModelInfo.empty(), :context_profiles, [%{raw_window: -1}])
    assert ModelInfo.merge([nil, invalid]) == ModelInfo.empty()
    assert ModelInfo.merge(nil) == ModelInfo.empty()
    assert ModelInfo.merge([mixed, ModelInfo.empty()]).description_state == :conflicting
    assert ModelInfo.merge([mixed, ModelInfo.empty()]).visibility == :mixed
    assert ModelInfo.merge([ModelInfo.empty()]).visibility == :unknown

    assert ModelInfo.merge([ModelInfo.from_sources([%{"context_window" => 1}])]).context_profiles !=
             []
  end
end
