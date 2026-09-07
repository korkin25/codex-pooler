defmodule CodexPooler.Platform.DNSClusterResolver do
  @moduledoc false

  @type dns_record :: :inet.ip_address()
  @type dns_record_type :: :a | :aaaa | :srv

  @spec basename(node()) :: String.t()
  def basename(node_name), do: DNSCluster.Resolver.basename(node_name)

  @spec connect_node(node()) :: boolean() | :ignored
  def connect_node(node_name), do: DNSCluster.Resolver.connect_node(node_name)

  @spec list_nodes() :: [node()]
  def list_nodes, do: DNSCluster.Resolver.list_nodes()

  @spec lookup(String.t(), dns_record_type()) :: [dns_record()]
  def lookup(query, type) do
    query
    |> DNSCluster.Resolver.lookup(type)
    |> reject_current_pod_ip()
  end

  @spec reject_current_pod_ip([dns_record()]) :: [dns_record()]
  def reject_current_pod_ip(records) do
    case System.get_env("POD_IP") do
      pod_ip when is_binary(pod_ip) and pod_ip != "" ->
        case :inet.parse_address(String.to_charlist(pod_ip)) do
          {:ok, address} -> Enum.reject(records, &(&1 == address))
          {:error, :einval} -> records
        end

      _missing_or_empty ->
        records
    end
  end
end
