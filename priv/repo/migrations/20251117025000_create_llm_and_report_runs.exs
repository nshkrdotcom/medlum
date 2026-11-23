defmodule Medlum.Repo.Migrations.CreateLlmAndReportRuns do
  use Ecto.Migration

  def change do
    create table(:llm_invocations, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false)
      add(:provider, :string, null: false)
      add(:model, :string, null: false)
      add(:prompt_text, :text, null: false)
      add(:prompt_context, :map, null: false, default: %{})
      add(:response_text, :text)
      add(:response_object, :map)
      add(:usage, :map, null: false, default: %{})
      add(:status, :string, null: false, default: "pending")
      add(:error, :map)
      add(:temperature, :float)
      add(:max_output_tokens, :integer)
      add(:req_duration_ms, :integer)
      add(:request_id, :string)

      timestamps(type: :utc_datetime)
    end

    create(index(:llm_invocations, [:tenant_id, :status]))

    create table(:report_runs, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false)

      add(:patient_id, references(:patients, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:template_id, references(:report_templates, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:triggered_by_user_id, references(:users, on_delete: :nilify_all))
      add(:run_type, :string, null: false, default: "full")
      add(:status, :string, null: false, default: "pending")

      add(
        :summary_invocation_id,
        references(:llm_invocations, type: :binary_id, on_delete: :nilify_all)
      )

      add(:started_at, :utc_datetime)
      add(:finished_at, :utc_datetime)

      timestamps(type: :utc_datetime)
    end

    create(index(:report_runs, [:tenant_id, :patient_id]))

    create table(:report_section_runs, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:report_run_id, references(:report_runs, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(
        :section_template_id,
        references(:report_section_templates, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:status, :string, null: false, default: "pending")

      add(
        :llm_invocation_id,
        references(:llm_invocations, type: :binary_id, on_delete: :nilify_all)
      )

      add(:prompt_inputs, :map, null: false, default: %{})
      add(:output_markdown, :text)
      add(:output_object, :map)
      add(:confidence_score, :float)
      add(:inline_citations, :map, null: false, default: %{})
      add(:provenance_graph, :map)
      add(:error, :map)

      timestamps(type: :utc_datetime)
    end

    create(index(:report_section_runs, [:report_run_id]))
    create(index(:report_section_runs, [:section_template_id, :status]))

    create table(:report_section_citations, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(
        :section_run_id,
        references(:report_section_runs, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:document_id, references(:document_uploads, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(
        :document_chunk_id,
        references(:document_chunks, type: :binary_id, on_delete: :nilify_all)
      )

      add(:citation_label, :string, null: false)
      add(:source_span, :map, null: false, default: %{})

      timestamps(type: :utc_datetime)
    end

    create(index(:report_section_citations, [:section_run_id]))

    create table(:report_section_feedback, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(
        :section_run_id,
        references(:report_section_runs, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:author_user_id, references(:users, on_delete: :nilify_all))
      add(:note, :text, null: false)
      add(:status, :string, null: false, default: "open")
      add(:resolution, :text)

      timestamps(type: :utc_datetime)
    end

    create(index(:report_section_feedback, [:section_run_id]))
  end
end
