defmodule Medlum.Conversion.Support.TestHelpers do
  @moduledoc """
  Test helpers for Conversion module tests.
  """

  @doc """
  Return a minimal valid PDF binary for testing.

  This is a minimal PDF 1.4 document that parsers will accept.
  """
  def sample_pdf do
    # Minimal valid PDF structure
    """
    %PDF-1.4
    1 0 obj
    << /Type /Catalog /Pages 2 0 R >>
    endobj
    2 0 obj
    << /Type /Pages /Kids [3 0 R] /Count 1 >>
    endobj
    3 0 obj
    << /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>
    endobj
    xref
    0 4
    0000000000 65535 f
    0000000009 00000 n
    0000000058 00000 n
    0000000115 00000 n
    trailer
    << /Size 4 /Root 1 0 R >>
    startxref
    193
    %%EOF
    """
  end

  @doc """
  Return the path to the sample PDF fixture file.
  """
  def sample_pdf_path do
    Path.join([File.cwd!(), "test", "fixtures", "sample.pdf"])
  end

  @doc """
  Read sample PDF from fixture file, falling back to generated minimal PDF.
  """
  def read_sample_pdf do
    path = sample_pdf_path()

    case File.read(path) do
      {:ok, content} -> content
      {:error, _} -> sample_pdf()
    end
  end

  @doc """
  Start a Bypass server for HTTP mocking.
  """
  def start_bypass do
    Bypass.open()
  end

  @doc """
  Build a base URL from a Bypass instance.
  """
  def bypass_url(bypass) do
    "http://localhost:#{bypass.port}"
  end

  @doc """
  Generate a unique job ID for testing.
  """
  def unique_job_id do
    "test-job-#{System.unique_integer([:positive])}"
  end

  @doc """
  Generate a unique tenant ID for testing.
  """
  def unique_tenant_id do
    Ecto.UUID.generate()
  end

  @doc """
  Generate a unique user ID for testing.
  """
  def unique_user_id do
    Ecto.UUID.generate()
  end

  @doc """
  Build job attributes for testing.
  """
  def job_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        profile: :standard,
        filename: "test.pdf",
        byte_size: 1024,
        tenant_id: unique_tenant_id(),
        user_id: unique_user_id()
      },
      overrides
    )
  end

  @doc """
  Attach a telemetry handler for test assertions.

  Returns the handler ID which can be used to detach later.
  """
  def attach_telemetry_handler(event_name, test_pid \\ self()) do
    handler_id = "test-handler-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      event_name,
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry_event, event, measurements, metadata})
      end,
      nil
    )

    handler_id
  end

  @doc """
  Detach a telemetry handler.
  """
  def detach_telemetry_handler(handler_id) do
    :telemetry.detach(handler_id)
  end

  @doc """
  Assert a telemetry event was received.
  """
  defmacro assert_telemetry_event(event_name, timeout \\ 1000) do
    quote do
      assert_receive {:telemetry_event, unquote(event_name), _measurements, _metadata},
                     unquote(timeout)
    end
  end

  @doc """
  Wait for a specific process state (useful for GenServer testing).
  """
  def wait_for_state(server, check_fn, timeout \\ 5000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    do_wait_for_state(server, check_fn, deadline)
  end

  defp do_wait_for_state(server, check_fn, deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      {:error, :timeout}
    else
      state = :sys.get_state(server)

      if check_fn.(state) do
        {:ok, state}
      else
        Process.sleep(50)
        do_wait_for_state(server, check_fn, deadline)
      end
    end
  end
end
