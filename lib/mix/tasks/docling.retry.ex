defmodule Mix.Tasks.Docling.Retry do
  @moduledoc """
  Retry a Docling ingestion job using the stored PDF.
  """

  use Mix.Task

  alias Medlum.Documents
  alias Medlum.Reports

  @shortdoc "Retry a failed Docling ingestion job"

  @impl true
  def run([job_id]) do
    Mix.Task.run("app.start", [])

    with {:ok, %{job: job}} <- Documents.fetch_ingestion_job(job_id),
         {:ok, template} <- fetch_template(job) do
      case Documents.retry_ingestion(job.upload_id, template: template) do
        {:ok, new_job} ->
          IO.puts("Re-queued upload #{job.upload_id} (new job #{new_job.id}) from #{job_id}")

        {:error, reason} ->
          IO.puts("Retry failed: #{inspect(reason)}")
      end
    else
      {:error, :not_found} ->
        IO.puts("Job not found: #{job_id}")

      {:error, :template_required} ->
        IO.puts("Template not found for job #{job_id}")
    end
  end

  def run(_args) do
    Mix.shell().error("Usage: mix docling.retry <job_id>")
  end

  defp fetch_template(job) do
    case job.metadata && Map.get(job.metadata, "template_id") do
      nil ->
        {:error, :template_required}

      template_id ->
        {:ok, Reports.get_template!(template_id)}
    end
  rescue
    _ -> {:error, :template_required}
  end
end
