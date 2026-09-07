defmodule CodexPooler.Catalog.Model do
  @moduledoc false
  use CodexPooler.Schema

  import Ecto.Changeset

  @statuses ~w(active stale retired suppressed)

  @type t :: %__MODULE__{}
  @type attrs :: map()

  schema "models" do
    field :pool_id, :binary_id
    field :upstream_model_id, :string
    field :exposed_model_id, :string
    field :display_name, :string
    field :status, :string
    field :supports_responses, :boolean
    field :supports_streaming, :boolean
    field :supports_tools, :boolean
    field :supports_reasoning, :boolean
    field :pricing_ref, :string
    field :source_assignment_count, :integer
    field :first_seen_at, :utc_datetime_usec
    field :last_seen_at, :utc_datetime_usec
    field :stale_at, :utc_datetime_usec
    field :retired_at, :utc_datetime_usec
    field :suppressed_at, :utc_datetime_usec
    field :last_sync_run_id, :binary_id
    field :metadata, :map
  end

  @spec changeset(t() | Ecto.Changeset.t(), attrs()) :: Ecto.Changeset.t()
  def changeset(model, attrs) do
    model
    |> cast(attrs, [
      :pool_id,
      :upstream_model_id,
      :exposed_model_id,
      :display_name,
      :status,
      :supports_responses,
      :supports_streaming,
      :supports_tools,
      :supports_reasoning,
      :pricing_ref,
      :source_assignment_count,
      :first_seen_at,
      :last_seen_at,
      :stale_at,
      :retired_at,
      :suppressed_at,
      :last_sync_run_id,
      :metadata
    ])
    |> update_change(:upstream_model_id, &trim_text/1)
    |> update_change(:exposed_model_id, &trim_text/1)
    |> update_change(:display_name, &trim_text/1)
    |> validate_required([
      :pool_id,
      :upstream_model_id,
      :exposed_model_id,
      :display_name,
      :status,
      :supports_responses,
      :supports_streaming,
      :supports_tools,
      :supports_reasoning,
      :source_assignment_count,
      :first_seen_at,
      :last_seen_at,
      :metadata
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:source_assignment_count, greater_than_or_equal_to: 0)
    |> unique_constraint(:exposed_model_id, name: :models_pool_exposed_uq)
  end

  defp trim_text(nil), do: nil
  defp trim_text(value), do: String.trim(value)
end
