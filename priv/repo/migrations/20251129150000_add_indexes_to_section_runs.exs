defmodule Lumainus.Repo.Migrations.AddIndexesToSectionRuns do
  use Ecto.Migration

  def change do
    create_if_not_exists(index(:report_section_runs, [:section_template_id]))
  end
end
