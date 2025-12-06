defmodule Lumainus.AI.LlmInvocation do
  use Ecto.Schema
  import Ecto.Changeset

  alias Lumainus.Tenancy.Tenant
  alias Lumainus.Reports.ReportSectionRun

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "llm_invocations" do
    field(:provider, :string)
    field(:model, :string)
    field(:prompt_text, :string)
    field(:prompt_context, :map, default: %{})
    field(:response_text, :string)
    field(:response_object, :map)
    field(:usage, :map, default: %{})
    field(:status, :string, default: "pending")
    field(:error, :map)
    field(:temperature, :float)
    field(:max_output_tokens, :integer)
    field(:req_duration_ms, :integer)
    field(:request_id, :string)
    field(:repair_status, :string, default: "none")

    # Response metadata for debugging
    field(:finish_reason, :string)
    field(:has_content, :boolean, default: true)
    field(:parts_count, :integer)

    # gemini_ex 0.6.4+ fields
    field(:response_id, :string)
    field(:model_version, :string)
    field(:finish_message, :string)
    field(:thoughts_token_count, :integer)
    field(:traffic_type, :string)

    belongs_to(:tenant, Tenant)
    has_one(:section_run, ReportSectionRun)

    timestamps(type: :utc_datetime)
  end

  @valid_statuses ["pending", "running", "completed", "error"]

  def changeset(invocation, attrs) do
    invocation
    |> cast(attrs, [
      :provider,
      :model,
      :prompt_text,
      :prompt_context,
      :response_text,
      :response_object,
      :usage,
      :status,
      :error,
      :temperature,
      :max_output_tokens,
      :req_duration_ms,
      :request_id,
      :repair_status,
      :finish_reason,
      :has_content,
      :parts_count,
      :response_id,
      :model_version,
      :finish_message,
      :thoughts_token_count,
      :traffic_type,
      :tenant_id
    ])
    |> validate_required([:provider, :model, :prompt_text, :tenant_id])
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_inclusion(:repair_status, ["none", "repaired", "failed"])
  end

  def valid_statuses, do: @valid_statuses
end
