defmodule MedlumWeb.Admin.Db.Filters.LlmReportRunFilter do
  use Backpex.Filters.Select

  import Ecto.Query

  alias Medlum.Repo
  alias Medlum.Reports.ReportRun

  @impl Backpex.Filter
  def label, do: "Report Run"

  @impl Backpex.Filters.Select
  def prompt, do: "All Report Runs"

  @impl Backpex.Filters.Select
  def options(_assigns) do
    ReportRun
    |> order_by([r], desc: r.inserted_at)
    |> limit(100)
    |> Repo.all()
    |> Enum.map(fn run ->
      label =
        "#{run.id |> String.slice(0..7)} - #{run.status} (#{Calendar.strftime(run.inserted_at, "%Y-%m-%d %H:%M")})"

      {label, run.id}
    end)
  end

  @impl Backpex.Filter
  def query(query, _attribute, value, _assigns) do
    query
    |> join(:inner, [i], sr in assoc(i, :section_run))
    |> where([i, sr], sr.report_run_id == ^value)
  end
end
