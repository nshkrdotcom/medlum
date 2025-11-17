defmodule Lumainus.Reports.ReportSectionFeedback do
  use Ecto.Schema
  import Ecto.Changeset

  alias Lumainus.Reports.ReportSectionRun
  alias Lumainus.Accounts.User

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "report_section_feedback" do
    field(:note, :string)
    field(:status, :string, default: "open")
    field(:resolution, :string)

    belongs_to(:section_run, ReportSectionRun)
    belongs_to(:author, User, foreign_key: :author_user_id, type: :id)

    timestamps(type: :utc_datetime)
  end

  def changeset(feedback, attrs) do
    feedback
    |> cast(attrs, [:note, :status, :resolution, :section_run_id, :author_user_id])
    |> validate_required([:note, :status, :section_run_id])
  end
end
