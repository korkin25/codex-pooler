defmodule CodexPooler.Upstreams.EndpointMetadata do
  @moduledoc false

  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}

  @default_base_url "https://chatgpt.com"
  @base_url_keys ~w(base_url api_base_url upstream_base_url)
  @usage_base_url_keys ~w(usage_base_url codex_usage_base_url)

  @spec base_url(UpstreamIdentity.t(), PoolUpstreamAssignment.t(), String.t()) ::
          String.t() | nil
  def base_url(identity, assignment, default \\ @default_base_url) do
    metadata_value(assignment.metadata, @base_url_keys) ||
      metadata_value(identity.metadata, @base_url_keys) ||
      default
  end

  @spec endpoint_url(UpstreamIdentity.t(), PoolUpstreamAssignment.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, :invalid_upstream_base_url}
  def endpoint_url(identity, assignment, endpoint, default \\ @default_base_url) do
    case base_url(identity, assignment, default) do
      base when is_binary(base) and base != "" ->
        base = normalize_base_url(base)

        case URI.new(base) do
          {:ok, %URI{scheme: scheme, host: host}}
          when scheme in ["http", "https"] and is_binary(host) and host != "" ->
            {:ok, base <> endpoint}

          _invalid ->
            {:error, :invalid_upstream_base_url}
        end

      _base ->
        {:error, :invalid_upstream_base_url}
    end
  end

  @spec usage_base_url(UpstreamIdentity.t(), PoolUpstreamAssignment.t(), String.t()) ::
          String.t() | nil
  def usage_base_url(identity, assignment, default \\ @default_base_url) do
    metadata_value(assignment.metadata, @usage_base_url_keys) ||
      metadata_value(identity.metadata, @usage_base_url_keys) ||
      base_url(identity, assignment, default)
  end

  @spec normalize_base_url(String.t()) :: String.t()
  def normalize_base_url(base) do
    base
    |> String.trim()
    |> String.trim_trailing("/")
    |> String.replace_suffix("/backend-api", "")
  end

  defp metadata_value(metadata, keys) when is_map(metadata) do
    Enum.find_value(keys, &Map.get(metadata, &1))
  end

  defp metadata_value(_metadata, _keys), do: nil
end
