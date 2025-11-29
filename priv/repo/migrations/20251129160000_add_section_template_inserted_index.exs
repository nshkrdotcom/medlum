defmodule Lumainus.Repo.Migrations.AddSectionTemplateInsertedIndex do
  use Ecto.Migration

  def change do
    create_if_not_exists(
      index(:report_section_runs, [:section_template_id, :inserted_at],
        order: [inserted_at: :desc]
      )
    )
  end
end
