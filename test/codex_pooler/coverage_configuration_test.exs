defmodule CodexPooler.CoverageConfigurationTest do
  use ExUnit.Case, async: true

  test "coverage excludes development support and retains application sources" do
    files = [
      %{path: "dev_support/mix/tasks/dev.seed.ex"},
      %{path: "lib/codex_pooler/files/create_validation.ex"},
      %{path: "lib/codex_pooler/upstreams/quota/windows/attributes.ex"}
    ]

    assert [validation, quotas] =
             Six.Stats.skip_files(files, Application.fetch_env!(:six, :skip_files))

    assert validation.path == "lib/codex_pooler/files/create_validation.ex"
    assert quotas.path == "lib/codex_pooler/upstreams/quota/windows/attributes.ex"
  end
end
