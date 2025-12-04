defmodule LumainusWeb.Admin.Db.LlmInvocationLive do
  use Backpex.LiveResource,
    layout: {LumainusWeb.AdminLayout, :app},
    adapter_config: [
      schema: Lumainus.AI.LlmInvocation,
      repo: Lumainus.Repo,
      update_changeset: &LumainusWeb.Admin.Db.ChangesetHelpers.llm_invocation_changeset/3,
      create_changeset: &LumainusWeb.Admin.Db.ChangesetHelpers.llm_invocation_changeset/3
    ],
    pubsub: [server: LumainusWeb.PubSub, topic: "llm_invocations"]

  @impl Backpex.LiveResource
  def singular_name, do: "LLM Invocation"

  @impl Backpex.LiveResource
  def plural_name, do: "LLM Invocations"

  @impl Backpex.LiveResource
  def fields do
    [
      id: %{module: Backpex.Fields.Text, label: "ID", readonly: true},
      provider: %{module: Backpex.Fields.Text, label: "Provider", searchable: true},
      model: %{module: Backpex.Fields.Text, label: "Model", searchable: true},
      status: %{
        module: Backpex.Fields.Select,
        label: "Status",
        options: [{"Pending", "pending"}, {"Success", "success"}, {"Error", "error"}]
      },
      temperature: %{module: Backpex.Fields.Number, label: "Temperature"},
      max_output_tokens: %{module: Backpex.Fields.Number, label: "Max Output Tokens"},
      req_duration_ms: %{module: Backpex.Fields.Number, label: "Duration (ms)", readonly: true},
      request_id: %{module: Backpex.Fields.Text, label: "Request ID", readonly: true},
      prompt_text: %{module: Backpex.Fields.Textarea, label: "Prompt Text", readonly: true},
      response_text: %{module: Backpex.Fields.Textarea, label: "Response Text", readonly: true},
      tenant: %{
        module: Backpex.Fields.BelongsTo,
        label: "Tenant",
        display_field: :name,
        live_resource: LumainusWeb.Admin.Db.TenantLive
      },
      inserted_at: %{module: Backpex.Fields.DateTime, label: "Created At", readonly: true},
      updated_at: %{module: Backpex.Fields.DateTime, label: "Updated At", readonly: true}
    ]
  end
end
