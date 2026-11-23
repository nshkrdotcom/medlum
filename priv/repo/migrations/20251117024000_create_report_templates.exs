defmodule Medlum.Repo.Migrations.CreateReportTemplates do
  use Ecto.Migration

  def change do
    create table(:report_templates, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false)
      add(:name, :string, null: false)
      add(:slug, :string, null: false)
      add(:description, :text)
      add(:status, :string, null: false, default: "active")
      add(:version, :integer, null: false, default: 1)
      add(:default_prompt_options, :map, null: false, default: %{})

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:report_templates, [:tenant_id, :slug]))

    create table(:report_section_templates, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:template_id, references(:report_templates, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:identifier, :string, null: false)
      add(:title, :string, null: false)
      add(:prompt_template, :text, null: false)
      add(:output_schema, :map, null: false, default: %{})
      add(:position, :integer, null: false, default: 0)
      add(:auto_run, :boolean, null: false, default: false)
      add(:provider, :string, null: false, default: "google")
      add(:model, :string, null: false, default: "gemini-flash-lite-latest")
      add(:temperature, :float, default: 0.2)
      add(:max_output_tokens, :integer, default: 2048)
      add(:metadata, :map, null: false, default: %{})

      timestamps(type: :utc_datetime)
    end

    create(index(:report_section_templates, [:template_id, :position]))
    create(unique_index(:report_section_templates, [:template_id, :identifier]))

    create table(:report_template_documents, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:template_id, references(:report_templates, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:document_kind, :string, null: false)
      add(:required, :boolean, null: false, default: true)

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:report_template_documents, [:template_id, :document_kind]))
  end
end
