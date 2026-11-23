defmodule Medlum.Reports.ReportSectionTemplate do
  use Ecto.Schema
  import Ecto.Changeset

  alias Medlum.Reports.{ReportTemplate, SchemaValidator}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "report_section_templates" do
    field(:identifier, :string)
    field(:title, :string)
    field(:prompt_template, :string)
    field(:output_schema, :map, default: %{})
    field(:position, :integer, default: 0)
    field(:auto_run, :boolean, default: false)
    field(:provider, :string, default: "google")
    field(:model, :string, default: "gemini-flash-lite-latest")
    field(:temperature, :float)
    field(:max_output_tokens, :integer)
    field(:metadata, :map, default: %{})

    # Sampling parameters
    field(:top_p, :float)
    field(:top_k, :integer)
    field(:candidate_count, :integer, default: 1)

    # Penalty parameters
    field(:presence_penalty, :float)
    field(:frequency_penalty, :float)

    # Control parameters
    field(:stop_sequences, {:array, :string}, default: [])
    field(:seed, :integer)

    # Context
    field(:system_prompt, :string)

    # Reliability
    field(:timeout_ms, :integer, default: 120_000)
    field(:max_retries, :integer, default: 3)
    field(:retry_delay_ms, :integer, default: 1000)

    # Fallback
    field(:fallback_provider, :string)
    field(:fallback_model, :string)

    # Response format
    field(:response_mime_type, :string, default: "application/json")

    belongs_to(:template, ReportTemplate)

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating/updating a section template.

  Validates:
  - Required fields: identifier, title, prompt_template, template_id
  - Unique constraint on template_id + identifier
  - Temperature range: 0.0 to 2.0
  - Top P range: 0.0 to 1.0
  - Penalties range: -2.0 to 2.0
  - Positive values for timeout, candidate_count
  - Non-negative values for top_k, max_retries
  - Output schema is valid JSON Schema for Gemini
  """
  def changeset(section, attrs) do
    section
    |> cast(attrs, [
      :identifier,
      :title,
      :prompt_template,
      :output_schema,
      :position,
      :auto_run,
      :provider,
      :model,
      :temperature,
      :max_output_tokens,
      :metadata,
      :template_id,
      # New fields
      :top_p,
      :top_k,
      :candidate_count,
      :presence_penalty,
      :frequency_penalty,
      :stop_sequences,
      :seed,
      :system_prompt,
      :timeout_ms,
      :max_retries,
      :retry_delay_ms,
      :fallback_provider,
      :fallback_model,
      :response_mime_type
    ])
    |> validate_required([:identifier, :title, :prompt_template, :template_id])
    |> unique_constraint([:template_id, :identifier])
    |> validate_number(:temperature, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 2.0)
    |> validate_number(:top_p, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> validate_number(:presence_penalty,
      greater_than_or_equal_to: -2.0,
      less_than_or_equal_to: 2.0
    )
    |> validate_number(:frequency_penalty,
      greater_than_or_equal_to: -2.0,
      less_than_or_equal_to: 2.0
    )
    |> validate_number(:candidate_count, greater_than_or_equal_to: 1)
    |> validate_number(:top_k, greater_than_or_equal_to: 0)
    |> validate_number(:timeout_ms, greater_than: 0)
    |> validate_number(:max_retries, greater_than_or_equal_to: 0)
    |> validate_output_schema()
  end

  # Validate output_schema is a valid JSON Schema for Gemini
  defp validate_output_schema(changeset) do
    case get_change(changeset, :output_schema) do
      nil ->
        changeset

      schema when is_map(schema) and map_size(schema) == 0 ->
        changeset

      schema ->
        case SchemaValidator.validate(schema) do
          {:ok, _} ->
            changeset

          {:error, message} ->
            add_error(changeset, :output_schema, message)
        end
    end
  end
end
