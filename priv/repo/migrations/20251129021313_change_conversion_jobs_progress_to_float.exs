defmodule Lumainus.Repo.Migrations.ChangeConversionJobsProgressToFloat do
  use Ecto.Migration

  def change do
    alter table(:conversion_jobs) do
      modify(:progress, :float, default: 0.0)
    end
  end
end
