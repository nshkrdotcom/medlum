defmodule Lumainus.Repo.Migrations.ExpandReportSections do
  use Ecto.Migration

  import Ecto.Query, warn: false

  alias Lumainus.Reports
  alias Lumainus.Reports.ReportSectionTemplate
  alias Lumainus.Repo
  alias __MODULE__.TemplateSnapshot

  def up do
    Repo.transaction(fn ->
      TemplateSnapshot
      |> Repo.all()
      |> Enum.each(&sync_template_sections/1)
    end)
  end

  def down, do: :ok

  defp sync_template_sections(template) do
    desired =
      template.id
      |> Reports.default_sections()
      |> Map.new(&{&1.identifier, &1})

    existing =
      ReportSectionTemplate
      |> where([s], s.template_id == ^template.id)
      |> Repo.all()
      |> Map.new(&{&1.identifier, &1})

    Enum.each(desired, fn {identifier, attrs} ->
      case Map.get(existing, identifier) do
        nil ->
          %ReportSectionTemplate{}
          |> ReportSectionTemplate.changeset(attrs)
          |> Repo.insert!()

        section ->
          section
          |> ReportSectionTemplate.changeset(%{
            title: attrs.title,
            prompt_template: attrs.prompt_template,
            output_schema: attrs.output_schema,
            position: attrs.position
          })
          |> Repo.update!()
      end
    end)
  end

  defmodule TemplateSnapshot do
    @moduledoc false
    # Minimal snapshot of report_templates to avoid selecting columns added after this migration
    use Ecto.Schema

    @primary_key {:id, :binary_id, autogenerate: false}
    @foreign_key_type :binary_id
    schema "report_templates" do
      field(:tenant_id, :binary_id)
      field(:slug, :string)
    end
  end
end
