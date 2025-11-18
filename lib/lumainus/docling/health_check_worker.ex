defmodule Lumainus.Docling.HealthCheckWorker do
  @moduledoc """
  Periodic Oban worker that stores Docling health probe results.
  """

  use Oban.Worker, queue: :health_checks, unique: [period: 60]

  alias Lumainus.Docling

  @impl Oban.Worker
  def perform(_job) do
    Docling.health()
    |> Docling.record_health()

    :ok
  end
end
