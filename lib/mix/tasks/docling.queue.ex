defmodule Mix.Tasks.Docling.Queue do
  @moduledoc """
  Inspect the most recent Docling ingestion jobs.
  """

  use Mix.Task

  import Ecto.Query, warn: false

  alias Medlum.Documents.IngestionJob
  alias Medlum.Repo

  @shortdoc "Print queued/running Docling ingestion jobs"

  @impl true
  def run(args) do
    Mix.Task.run("app.start", [])

    limit = parse_limit(args)

    IngestionJob
    |> order_by([j], desc: j.inserted_at)
    |> preload(:upload)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.each(&print_job/1)
  end

  defp print_job(job) do
    upload_label =
      case job.upload do
        nil -> "unknown upload"
        upload -> "#{upload.filename} (#{upload.id})"
      end

    IO.puts([
      job.id,
      " [",
      job.state,
      "/",
      job.stage,
      "] ",
      Integer.to_string(job.progress || 0),
      "% - ",
      upload_label
    ])

    if job.last_message do
      IO.puts("  message: #{job.last_message}")
    end

    if job.last_error do
      IO.puts("  error: #{job.last_error}")
    end

    IO.puts("")
  end

  defp parse_limit([value | _]) do
    case Integer.parse(value) do
      {int, _} when int > 0 -> int
      _ -> 20
    end
  end

  defp parse_limit(_), do: 20
end
