defmodule CodexPooler.Files.CreateValidationTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Files
  alias CodexPooler.Files.CreateValidation
  alias CodexPooler.Gateway.OperationalSettings

  setup do
    previous = Application.get_env(:codex_pooler, Files, [])
    Application.put_env(:codex_pooler, Files, max_file_size_bytes: 64)
    on_exit(fn -> Application.put_env(:codex_pooler, Files, previous) end)
    :ok
  end

  test "normalizes string and atom keys, whitespace, and default use case" do
    for params <- [
          %{file_name: " sample.txt ", file_size: " 64 "},
          %{"file_name" => " sample.txt ", "file_size" => 64, "use_case" => " "},
          %{file_name: "sample.txt", file_size: 64, use_case: " codex "}
        ] do
      assert {:ok, %{file_name: "sample.txt", file_size: 64, use_case: "codex"}} =
               CreateValidation.create_params(params)
    end
  end

  test "rejects non-object input, missing names, invalid sizes and unsupported use cases" do
    for params <- [nil, [], "sample"] do
      assert {:error, %{status: 400, code: :invalid_request}} =
               CreateValidation.create_params(params)
    end

    for size <- [nil, false, %{}, [], 0, -1, 0.5, "1.5", "1x", "0", ""] do
      assert {:error, %{param: "file_size"}} =
               CreateValidation.create_params(%{file_name: "sample.txt", file_size: size})
    end

    assert {:error, %{param: "file_name"}} = CreateValidation.create_params(%{file_size: 1})

    assert {:error, %{param: "file_size"}} =
             CreateValidation.create_params(%{file_name: "sample.txt", file_size: 65})

    assert {:error, %{param: "use_case"}} =
             CreateValidation.create_params(%{
               file_name: "sample.txt",
               file_size: 1,
               use_case: "other"
             })
  end

  test "requires nonblank upstream identifiers and upload URLs" do
    assert {:ok, "file_sample"} =
             CreateValidation.upstream_file_id(%{"file_id" => " file_sample "})

    assert :ok =
             CreateValidation.upload_url_present(%{"upload_url" => "https://example.com/upload"})

    for value <- [nil, false, 1, [], %{}, "", " \n "] do
      assert {:error, %{status: 502, code: :upstream_file_bridge_invalid_response}} =
               CreateValidation.upstream_file_id(%{"file_id" => value})

      assert {:error, %{status: 502, code: :upstream_file_bridge_invalid_response}} =
               CreateValidation.upload_url_present(%{"upload_url" => value})
    end

    assert {:error, %{status: 502}} = CreateValidation.upstream_file_id(%{})
    assert {:error, %{status: 502}} = CreateValidation.upload_url_present(%{})
  end

  test "invalid size overrides fall back to operational settings" do
    expected = OperationalSettings.current().file_max_size_bytes

    for value <- [nil, 0, -1, "64"] do
      Application.put_env(:codex_pooler, Files, max_file_size_bytes: value)
      assert CreateValidation.max_file_size_bytes() == expected
    end
  end
end
