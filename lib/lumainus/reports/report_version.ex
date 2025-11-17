defmodule Lumainus.Reports.ReportVersion do
  use Ecto.Schema
  import Ecto.Changeset

  alias Lumainus.Reports.{Report, ReportRun}
  alias Lumainus.Accounts.User

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "report_versions" do
    field(:version, :integer)
    field(:body, :string)
    field(:structured_payload, :map, default: %{})

    belongs_to(:report, Report)
    belongs_to(:generated_from_run, ReportRun, foreign_key: :generated_from_run_id)
    belongs_to(:created_by, User, foreign_key: :created_by_user_id, type: :id)

    timestamps(type: :utc_datetime)
  end

  def changeset(version_struct, attrs) do
    version_struct
    |> cast(attrs, [
      :version,
      :body,
      :structured_payload,
      :report_id,
      :generated_from_run_id,
      :created_by_user_id
    ])
    |> validate_required([:version, :body, :report_id])
  end
end
