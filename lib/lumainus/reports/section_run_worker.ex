defmodule Lumainus.Reports.SectionRunWorker do
  @moduledoc """
  Oban worker responsible for executing report section runs asynchronously.
  """

  use Oban.Worker, queue: :reports, max_attempts: 3

  alias Ecto.Changeset
  alias Lumainus.Accounts.Scope
  alias Lumainus.AI.SectionRunner
  alias Lumainus.Reports.{ReportRun, ReportSectionRun, RunReconciler}
  alias Lumainus.{Repo, Reports}

  @impl true
  def perform(%Oban.Job{args: %{"section_run_id" => section_run_id} = args}) do
    stream? = Map.get(args, "stream", false)

    section_run =
      ReportSectionRun
      |> Repo.get!(section_run_id)
      |> Repo.preload([
        :section_template,
        report_run: [:template, :patient, :record_set]
      ])

    report_run = ensure_run_running(section_run.report_run)
    patient = Repo.preload(report_run.patient, :current_profile)
    scope = %Scope{tenant_id: report_run.tenant_id}
    documents = Reports.list_documents_with_chunks(scope, report_run.record_set)

    result =
      if stream? do
        SectionRunner.run_section_streaming(scope, section_run, patient, documents)
      else
        SectionRunner.run_section(scope, section_run, patient, documents)
      end

    case result do
      {:ok, _run} ->
        # Only finalize and notify on success
        RunReconciler.maybe_finalize(report_run.id)
        Reports.notify_section_run_update(report_run.record_set_id)
        :ok

      {:error, run} ->
        # Notify so UI updates to show "Retrying..." status
        Reports.notify_section_run_update(report_run.record_set_id)
        # Check if this is a rate limit error with retry_after information
        # If so, use Oban's snooze to wait appropriately
        case extract_rate_limit_info(run.error) do
          {:rate_limited, retry_after_seconds} ->
            # Use Oban's snooze to delay retry until after rate limit window
            {:snooze, retry_after_seconds}

          :not_rate_limited ->
            # Return error to Oban so it will retry (up to max_attempts)
            # When max_attempts is exhausted, ObanTelemetryHandler will mark as "failed"
            error_msg = run.error["message"] || "Section run failed"
            {:error, error_msg}
        end
    end
  end

  # Extract retry_after information from rate limit errors
  defp extract_rate_limit_info(error) when is_map(error) do
    # Check if this is a rate limit error (type: :rate_limit or details about rate limiting)
    cond do
      rate_limit_error?(error) ->
        # Try to extract retry_after from various possible locations
        # Default to 60 seconds if no specific retry_after found
        retry_after_seconds =
          extract_retry_after_seconds(error) ||
            extract_retry_after_from_retry_at(error) ||
            60

        {:rate_limited, retry_after_seconds}

      true ->
        :not_rate_limited
    end
  end

  defp extract_rate_limit_info(_), do: :not_rate_limited

  # Check if error indicates rate limiting (429 or rate_limit type)
  defp rate_limit_error?(%{"type" => "rate_limit"}), do: true
  defp rate_limit_error?(%{"type" => "rate_limited"}), do: true
  defp rate_limit_error?(%{"http_status" => 429}), do: true

  defp rate_limit_error?(%{"message" => msg}) when is_binary(msg) do
    String.contains?(msg, ["rate limit", "Rate limit", "429", "quota"])
  end

  defp rate_limit_error?(_), do: false

  # Extract retry_after_seconds from error details
  defp extract_retry_after_seconds(%{"details" => details}) when is_map(details) do
    Map.get(details, "retry_after_seconds") || Map.get(details, :retry_after_seconds)
  end

  defp extract_retry_after_seconds(_), do: nil

  # Extract retry_after from retry_at DateTime
  defp extract_retry_after_from_retry_at(%{"retry_at" => retry_at}) when is_binary(retry_at) do
    case DateTime.from_iso8601(retry_at) do
      {:ok, dt, _} ->
        max(DateTime.diff(dt, DateTime.utc_now(), :second), 0)

      _ ->
        nil
    end
  end

  defp extract_retry_after_from_retry_at(%{"details" => details}) when is_map(details) do
    retry_at = Map.get(details, "retry_at") || Map.get(details, :retry_at)

    case retry_at do
      %DateTime{} = dt ->
        max(DateTime.diff(dt, DateTime.utc_now(), :second), 0)

      _ ->
        nil
    end
  end

  defp extract_retry_after_from_retry_at(_), do: nil

  defp ensure_run_running(%ReportRun{} = report_run) do
    now = DateTime.utc_now(:second)

    if report_run.status in ["queued", "pending"] do
      Repo.update!(
        Changeset.change(report_run, %{
          status: "running",
          started_at: now,
          last_activity_at: now
        })
      )
    else
      report_run
    end
  end
end
