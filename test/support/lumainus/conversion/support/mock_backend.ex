defmodule Lumainus.Conversion.Support.MockBackend do
  @moduledoc """
  Per-test mock backend using Agent for state isolation.

  Each test starts its own Agent instance via `start_supervised!/1` to ensure
  complete isolation between tests.

  ## Usage

      setup do
        mock = start_supervised!({MockBackend, name: :"mock_#{System.unique_integer()}"})
        MockBackend.set_health(mock, {:ok, %{"status" => "healthy"}})
        {:ok, mock: mock}
      end

      test "enqueue succeeds", %{mock: mock} do
        MockBackend.set_enqueue_response(mock, {:ok, %{"job_id" => "test-123"}})
        assert {:ok, _} = MockBackend.enqueue(mock, <<>>, [])
      end
  """

  @behaviour Lumainus.Conversion.Backend

  use Agent

  defstruct enqueue_response: {:ok, %{"job_id" => "mock-job-id", "state" => "queued"}},
            await_response: {:ok, %{"markdown" => "# Mock Result", "metadata" => %{}}},
            status_response: {:ok, %{"state" => "completed", "progress" => 100}},
            health_response: {:ok, %{"status" => "healthy", "version" => "mock"}},
            cancel_response: :ok,
            enqueue_calls: [],
            await_calls: [],
            status_calls: [],
            health_calls: [],
            cancel_calls: []

  # Agent API

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Agent.start_link(fn -> %__MODULE__{} end, name: name)
  end

  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  # Configuration setters

  def set_enqueue_response(agent, response) do
    Agent.update(agent, &%{&1 | enqueue_response: response})
  end

  def set_await_response(agent, response) do
    Agent.update(agent, &%{&1 | await_response: response})
  end

  def set_status_response(agent, response) do
    Agent.update(agent, &%{&1 | status_response: response})
  end

  def set_health_response(agent, response) do
    Agent.update(agent, &%{&1 | health_response: response})
  end

  def set_cancel_response(agent, response) do
    Agent.update(agent, &%{&1 | cancel_response: response})
  end

  # Call history getters

  def get_enqueue_calls(agent) do
    Agent.get(agent, & &1.enqueue_calls)
  end

  def get_await_calls(agent) do
    Agent.get(agent, & &1.await_calls)
  end

  def get_status_calls(agent) do
    Agent.get(agent, & &1.status_calls)
  end

  def get_health_calls(agent) do
    Agent.get(agent, & &1.health_calls)
  end

  def get_cancel_calls(agent) do
    Agent.get(agent, & &1.cancel_calls)
  end

  # Backend behavior implementation (with explicit agent parameter)

  def enqueue(agent, binary, opts) when is_pid(agent) or is_atom(agent) do
    Agent.get_and_update(agent, fn state ->
      call = %{binary: binary, opts: opts, timestamp: DateTime.utc_now()}
      new_state = %{state | enqueue_calls: [call | state.enqueue_calls]}
      {state.enqueue_response, new_state}
    end)
  end

  def await(agent, job_ref, opts) when is_pid(agent) or is_atom(agent) do
    Agent.get_and_update(agent, fn state ->
      call = %{job_ref: job_ref, opts: opts, timestamp: DateTime.utc_now()}
      new_state = %{state | await_calls: [call | state.await_calls]}
      {state.await_response, new_state}
    end)
  end

  def status(agent, job_id) when is_pid(agent) or is_atom(agent) do
    Agent.get_and_update(agent, fn state ->
      call = %{job_id: job_id, timestamp: DateTime.utc_now()}
      new_state = %{state | status_calls: [call | state.status_calls]}
      {state.status_response, new_state}
    end)
  end

  def health(agent) when is_pid(agent) or is_atom(agent) do
    Agent.get_and_update(agent, fn state ->
      call = %{timestamp: DateTime.utc_now()}
      new_state = %{state | health_calls: [call | state.health_calls]}
      {state.health_response, new_state}
    end)
  end

  def cancel(agent, job_id) when is_pid(agent) or is_atom(agent) do
    Agent.get_and_update(agent, fn state ->
      call = %{job_id: job_id, timestamp: DateTime.utc_now()}
      new_state = %{state | cancel_calls: [call | state.cancel_calls]}
      {state.cancel_response, new_state}
    end)
  end

  # Backend behaviour callbacks (using module name as default agent)

  @impl true
  def enqueue(binary, opts) do
    enqueue(__MODULE__, binary, opts)
  end

  @impl true
  def await(job_ref, opts) do
    await(__MODULE__, job_ref, opts)
  end

  @impl true
  def status(job_id) do
    status(__MODULE__, job_id)
  end

  @impl true
  def health do
    health(__MODULE__)
  end

  @impl true
  def cancel(job_id) do
    cancel(__MODULE__, job_id)
  end

  @impl true
  def name, do: :mock

  @impl true
  def backend_type, do: :local
end
