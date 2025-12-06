defmodule LumainusWeb.Admin.Db.LlmInvocationLive do
  use Backpex.LiveResource,
    layout: {LumainusWeb.AdminLayout, :app},
    adapter_config: [
      schema: Lumainus.AI.LlmInvocation,
      repo: Lumainus.Repo,
      update_changeset: &LumainusWeb.Admin.Db.ChangesetHelpers.llm_invocation_changeset/3,
      create_changeset: &LumainusWeb.Admin.Db.ChangesetHelpers.llm_invocation_changeset/3,
      item_query: &__MODULE__.item_query/3
    ],
    pubsub: [server: LumainusWeb.PubSub, topic: "llm_invocations"],
    init_order: %{by: :inserted_at, direction: :desc},
    per_page_options: [15, 30, 50],
    per_page_default: 15

  import Ecto.Query
  import LumainusWeb.Admin.Db.BackpexHelpers

  def item_query(query, _live_action, _assigns) do
    from(q in query, preload: [:tenant])
  end

  @impl Backpex.LiveResource
  def singular_name, do: "LLM Invocation"

  @impl Backpex.LiveResource
  def plural_name, do: "LLM Invocations"

  @impl Backpex.LiveResource
  def filters(_assigns) do
    [
      report_run: %{
        module: LumainusWeb.Admin.Db.Filters.LlmReportRunFilter
      }
    ]
  end

  @impl Backpex.LiveResource
  def fields do
    [
      id: %{module: Backpex.Fields.Text, label: "ID", readonly: true},
      provider: %{module: Backpex.Fields.Text, label: "Provider", searchable: true},
      model: %{module: Backpex.Fields.Text, label: "Model", searchable: true},
      status: %{
        module: Backpex.Fields.Select,
        label: "Status",
        options: [{"Pending", "pending"}, {"Completed", "completed"}, {"Error", "error"}]
      },
      repair_status: %{
        module: Backpex.Fields.Select,
        label: "Repair",
        options: [{"None", "none"}, {"Repaired", "repaired"}, {"Failed", "failed"}]
      },
      finish_reason: %{
        module: Backpex.Fields.Text,
        label: "Finish Reason",
        readonly: true,
        render: fn assigns ->
          value = assigns.value
          text = if is_nil(value), do: "-", else: value
          assigns = Map.put(assigns, :text, text)

          ~H(<span class={if @text not in ["-", "STOP"], do: "text-red-600 font-semibold", else: ""}>
  {@text}
</span>)
        end
      },
      has_content: %{
        module: Backpex.Fields.Boolean,
        label: "Has Content",
        readonly: true
      },
      parts_count: %{
        module: Backpex.Fields.Number,
        label: "Parts",
        readonly: true,
        render: fn assigns ->
          value = assigns.value
          text = if is_nil(value), do: "-", else: to_string(value)
          assigns = Map.put(assigns, :text, text)
          ~H(<span>{@text}</span>)
        end
      },
      error: %{
        module: Backpex.Fields.Text,
        label: "Error",
        readonly: true,
        render: fn assigns ->
          error = assigns.value

          text =
            cond do
              is_nil(error) -> "-"
              is_map(error) -> Jason.encode!(error, pretty: true)
              true -> inspect(error)
            end

          assigns = Map.put(assigns, :text, text)
          ~H(<pre class="text-xs whitespace-pre-wrap max-w-xs overflow-auto"><%= @text %></pre>)
        end
      },
      temperature: %{
        module: Backpex.Fields.Number,
        label: "Temperature",
        render: fn assigns ->
          value = assigns.value
          text = if is_nil(value), do: "-", else: to_string(value)
          assigns = Map.put(assigns, :text, text)
          ~H(<span>{@text}</span>)
        end
      },
      max_output_tokens: %{module: Backpex.Fields.Number, label: "Max Output Tokens"},
      req_duration_ms: %{module: Backpex.Fields.Number, label: "Duration (ms)", readonly: true},
      request_id: %{module: Backpex.Fields.Text, label: "Request ID", readonly: true},
      prompt_text: %{
        module: Backpex.Fields.Textarea,
        label: "Prompt Text",
        readonly: true,
        except: [:index]
      },
      response_text: %{
        module: Backpex.Fields.Textarea,
        label: "Response Text",
        readonly: true,
        except: [:index]
      },
      tenant: %{
        module: Backpex.Fields.BelongsTo,
        label: "Tenant",
        display_field: :name,
        live_resource: LumainusWeb.Admin.Db.TenantLive
      },
      inserted_at: %{
        module: Backpex.Fields.DateTime,
        label: "Created At",
        readonly: true,
        render: datetime_render()
      },
      updated_at: %{
        module: Backpex.Fields.DateTime,
        label: "Updated At",
        readonly: true,
        render: datetime_render()
      }
    ]
  end
end
