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

    belongs_to(:tenant, Tenant)
    has_one(:section_run, ReportSectionRun)

    timestamps(type: :utc_datetime)
  end

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
      :tenant_id
    ])
    |> validate_required([:provider, :model, :prompt_text, :tenant_id])
    |> validate_inclusion(:repair_status, ["none", "repaired", "failed"])
  end
end
