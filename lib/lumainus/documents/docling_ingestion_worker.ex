defmodule Lumainus.Documents.DoclingIngestionWorker do
  @moduledoc """
  Oban worker responsible for running Docling ingestion for uploads.
  """

  use Oban.Worker, queue: :ingestion, max_attempts: 5

  alias Lumainus.Documents.IngestionProcessor

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"ingestion_job_id" => job_id}}) do
    case IngestionProcessor.process(job_id) do
      :ok -> :ok
      {:error, _reason} -> {:error, :ingestion_failed}
    end
  end
end
