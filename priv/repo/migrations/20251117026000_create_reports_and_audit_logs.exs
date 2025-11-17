defmodule Lumainus.Repo.Migrations.CreateReportsAndAuditLogs do
  use Ecto.Migration

  def change do
    create table(:reports, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false)

      add(:patient_id, references(:patients, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:template_id, references(:report_templates, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:report_run_id, references(:report_runs, type: :binary_id, on_delete: :nilify_all))
      add(:title, :string, null: false)
      add(:summary, :text)
      add(:body, :text)
      add(:status, :string, null: false, default: "draft")
      add(:published_at, :utc_datetime)

      timestamps(type: :utc_datetime)
    end

    create(index(:reports, [:tenant_id, :patient_id]))

    alter table(:reports) do
      add(:superseded_by_id, references(:reports, type: :binary_id, on_delete: :nilify_all))
    end

    create table(:report_versions, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:report_id, references(:reports, type: :binary_id, on_delete: :delete_all), null: false)
      add(:version, :integer, null: false)
      add(:body, :text, null: false)
      add(:structured_payload, :map, null: false, default: %{})

      add(
        :generated_from_run_id,
        references(:report_runs, type: :binary_id, on_delete: :nilify_all)
      )

      add(:created_by_user_id, references(:users, on_delete: :nilify_all))

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:report_versions, [:report_id, :version]))

    create table(:audit_logs, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false)
      add(:actor_id, references(:users, on_delete: :nilify_all))
      add(:event_type, :string, null: false)
      add(:entity_type, :string, null: false)
      add(:entity_id, :binary_id)
      add(:metadata, :map, null: false, default: %{})
      add(:recorded_at, :utc_datetime, null: false)

      timestamps(type: :utc_datetime)
    end

    create(index(:audit_logs, [:tenant_id, :event_type]))
  end
end
