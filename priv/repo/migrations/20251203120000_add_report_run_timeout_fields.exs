defmodule Lumainus.Repo.Migrations.AddReportRunTimeoutFields do
  use Ecto.Migration

  def change do
    alter table(:report_runs) do
      add(:timeout_at, :utc_datetime)
      add(:last_activity_at, :utc_datetime)
    end

    # Index for staleness queries
    create(index(:report_runs, [:status, :timeout_at]))
    create(index(:report_runs, [:status, :last_activity_at]))
  end
end
