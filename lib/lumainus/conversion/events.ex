defmodule Lumainus.Conversion.Events do
  @moduledoc """
  PubSub event broadcasting for conversion jobs.

  ## Usage

  LiveViews and other processes can subscribe to job updates:

      # Subscribe to a specific job's events
      Events.subscribe(job_id)

      # Handle events in handle_info
      def handle_info({:conversion_job, :submitted, job}, socket) do
        # ...
      end

      def handle_info({:conversion_job, :progress, %{job_id: id, progress: p}}, socket) do
        # ...
      end

      def handle_info({:conversion_job, :completed, job}, socket) do
        # ...
      end

      def handle_info({:conversion_job, :failed, %{job_id: id, reason: r}}, socket) do
        # ...
      end

      def handle_info({:conversion_job, :cancelled, job}, socket) do
        # ...
      end

  ## Events

  - `{:conversion_job, :submitted, job}` — Job submitted
  - `{:conversion_job, :progress, %{job_id: id, progress: percent}}` — Progress update
  - `{:conversion_job, :completed, job}` — Job completed successfully
  - `{:conversion_job, :failed, %{job_id: id, reason: reason}}` — Job failed
  - `{:conversion_job, :cancelled, job}` — Job cancelled
  """

  alias Phoenix.PubSub

  @pubsub LumainusWeb.PubSub
  @topic_prefix "conversion:job:"

  # ============================================================================
  # Subscription
  # ============================================================================

  @doc """
  Subscribe to events for a specific job.

  Returns `:ok` on success.
  """
  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(job_id) when is_binary(job_id) do
    PubSub.subscribe(@pubsub, topic(job_id))
  end

  @doc """
  Unsubscribe from events for a specific job.
  """
  @spec unsubscribe(String.t()) :: :ok | {:error, term()}
  def unsubscribe(job_id) when is_binary(job_id) do
    PubSub.unsubscribe(@pubsub, topic(job_id))
  end

  # ============================================================================
  # Broadcasting
  # ============================================================================

  @doc """
  Broadcast that a job has been submitted.
  """
  @spec broadcast_submitted(map()) :: :ok | {:error, term()}
  def broadcast_submitted(%{id: job_id} = job) do
    broadcast(job_id, {:conversion_job, :submitted, job})
  end

  @doc """
  Broadcast job progress update.
  """
  @spec broadcast_progress(map(), integer()) :: :ok | {:error, term()}
  def broadcast_progress(%{id: job_id}, progress) when is_integer(progress) do
    broadcast(job_id, {:conversion_job, :progress, %{job_id: job_id, progress: progress}})
  end

  @doc """
  Broadcast that a job has completed successfully.
  """
  @spec broadcast_completed(map()) :: :ok | {:error, term()}
  def broadcast_completed(%{id: job_id} = job) do
    broadcast(job_id, {:conversion_job, :completed, job})
  end

  @doc """
  Broadcast that a job has failed.
  """
  @spec broadcast_failed(map(), term()) :: :ok | {:error, term()}
  def broadcast_failed(%{id: job_id}, reason) do
    broadcast(job_id, {:conversion_job, :failed, %{job_id: job_id, reason: reason}})
  end

  @doc """
  Broadcast that a job has been cancelled.
  """
  @spec broadcast_cancelled(map()) :: :ok | {:error, term()}
  def broadcast_cancelled(%{id: job_id} = job) do
    broadcast(job_id, {:conversion_job, :cancelled, job})
  end

  # ============================================================================
  # Topic Helper
  # ============================================================================

  @doc """
  Generate the topic for a job ID.

  Exposed for testing purposes.
  """
  @spec topic(String.t()) :: String.t()
  def topic(job_id) when is_binary(job_id) do
    @topic_prefix <> job_id
  end

  # ============================================================================
  # Private
  # ============================================================================

  defp broadcast(job_id, message) do
    PubSub.broadcast(@pubsub, topic(job_id), message)
  end
end
