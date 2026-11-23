defmodule Medlum.Repo.Migrations.CreateExternalApiLogs do
  use Ecto.Migration

  def change do
    create table(:external_api_logs, primary_key: false) do
      add(:id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:service, :string, null: false)
      add(:method, :string, null: false)
      add(:path, :string, null: false)
      add(:status, :integer)
      add(:latency_ms, :integer, null: false)
      add(:error, :text)

      timestamps(inserted_at: :inserted_at, updated_at: false, type: :utc_datetime_usec)
    end

    create(index(:external_api_logs, [:service]))
    create(index(:external_api_logs, [:inserted_at]))
    create(index(:external_api_logs, [:service, :inserted_at]))
  end
end
