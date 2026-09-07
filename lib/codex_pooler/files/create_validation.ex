defmodule CodexPooler.Files.CreateValidation do
  @moduledoc false

  alias CodexPooler.Gateway.OperationalSettings

  @default_max_file_size_bytes 25 * 1024 * 1024
  @default_use_case "codex"
  @supported_use_cases MapSet.new([@default_use_case])

  @type file_error :: CodexPooler.Files.file_error()

  @spec max_file_size_bytes() :: pos_integer()
  def max_file_size_bytes do
    config_max_file_size_bytes() || OperationalSettings.current().file_max_size_bytes ||
      @default_max_file_size_bytes
  end

  @spec create_params(map()) :: {:ok, map()} | {:error, file_error()}
  def create_params(params) when is_map(params) do
    with {:ok, file_name} <- required_string(params, :file_name),
         {:ok, file_size} <- required_positive_integer(params, :file_size),
         :ok <- enforce_file_size_limit(file_size),
         {:ok, use_case} <- normalize_use_case(params) do
      {:ok, %{file_name: file_name, file_size: file_size, use_case: use_case}}
    end
  end

  def create_params(_params),
    do: {:error, error(400, :invalid_request, "request body must be a JSON object")}

  @spec upstream_file_id(map()) :: {:ok, binary()} | {:error, file_error()}
  def upstream_file_id(%{"file_id" => file_id}) when is_binary(file_id) do
    file_id = String.trim(file_id)

    if file_id == "",
      do:
        {:error,
         error(
           502,
           :upstream_file_bridge_invalid_response,
           "upstream file create did not return a file_id"
         )},
      else: {:ok, file_id}
  end

  def upstream_file_id(_body),
    do:
      {:error,
       error(
         502,
         :upstream_file_bridge_invalid_response,
         "upstream file create did not return a file_id"
       )}

  @spec upload_url_present(map()) :: :ok | {:error, file_error()}
  def upload_url_present(%{"upload_url" => upload_url}) when is_binary(upload_url) do
    if String.trim(upload_url) == "",
      do:
        {:error,
         error(
           502,
           :upstream_file_bridge_invalid_response,
           "upstream file create did not return an upload_url"
         )},
      else: :ok
  end

  def upload_url_present(_body),
    do:
      {:error,
       error(
         502,
         :upstream_file_bridge_invalid_response,
         "upstream file create did not return an upload_url"
       )}

  defp required_string(params, key) do
    case param_value(params, key) do
      nil ->
        {:error, error(400, :invalid_request, "#{key} is required", Atom.to_string(key))}

      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, error(400, :invalid_request, "#{key} is required", Atom.to_string(key))}
          value -> {:ok, value}
        end

      _value ->
        {:error, error(400, :invalid_request, "#{key} must be a string", Atom.to_string(key))}
    end
  end

  defp required_positive_integer(params, key) do
    case param_value(params, key) do
      value when is_integer(value) and value > 0 ->
        {:ok, value}

      value when is_binary(value) ->
        case Integer.parse(String.trim(value)) do
          {integer, ""} when integer > 0 ->
            {:ok, integer}

          _invalid ->
            {:error,
             error(
               400,
               :invalid_request,
               "#{key} must be a positive integer",
               Atom.to_string(key)
             )}
        end

      _value ->
        {:error,
         error(
           400,
           :invalid_request,
           "#{key} must be a positive integer",
           Atom.to_string(key)
         )}
    end
  end

  defp enforce_file_size_limit(file_size) do
    if file_size <= max_file_size_bytes() do
      :ok
    else
      {:error, error(400, :invalid_request, "file_size exceeds the supported limit", "file_size")}
    end
  end

  defp normalize_use_case(params) do
    case param_value(params, :use_case) do
      nil -> {:ok, @default_use_case}
      value when is_binary(value) -> validate_use_case(String.trim(value))
      _value -> {:error, error(400, :invalid_request, "use_case must be a string", "use_case")}
    end
  end

  defp validate_use_case(use_case) do
    case use_case do
      "" ->
        {:ok, @default_use_case}

      supported ->
        if MapSet.member?(@supported_use_cases, supported) do
          {:ok, supported}
        else
          {:error, error(400, :invalid_request, "use_case is not supported", "use_case")}
        end
    end
  end

  defp param_value(params, key),
    do: Map.get(params, Atom.to_string(key), Map.get(params, key))

  defp error(status, code, message, param \\ nil),
    do: %{status: status, code: code, message: message, param: param}

  defp config_max_file_size_bytes do
    :codex_pooler
    |> Application.get_env(CodexPooler.Files, [])
    |> Keyword.get(:max_file_size_bytes)
    |> positive_integer_or_nil()
  end

  defp positive_integer_or_nil(value) when is_integer(value) and value > 0, do: value
  defp positive_integer_or_nil(_value), do: nil
end
