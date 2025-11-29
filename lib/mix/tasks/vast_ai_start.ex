defmodule Mix.Tasks.VastAi.Start do
  @moduledoc """
  Start a stopped Vast.ai GPU instance.

  This starts a previously stopped instance. It's much faster than
  provisioning a new one since the Docker image is already pulled.

  ## Usage

      mix vast_ai.start

  ## Options

    * `--id INSTANCE_ID` - Start a specific instance
    * `--wait` - Wait for instance to be fully ready (default: true)
    * `--timeout SECONDS` - Timeout for waiting (default: 60)

  ## Examples

      mix vast_ai.start
      mix vast_ai.start --id 12345678
      mix vast_ai.start --timeout 120

  """
  use Mix.Task

  @shortdoc "Start a stopped Vast.ai GPU instance"

  @impl true
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [id: :integer, wait: :boolean, timeout: :integer],
        aliases: [i: :id, w: :wait, t: :timeout]
      )

    # Start the application
    Mix.Task.run("app.start", [])

    specific_id = Keyword.get(opts, :id)
    should_wait = Keyword.get(opts, :wait, true)
    timeout_seconds = Keyword.get(opts, :timeout, 60)

    alias Lumainus.VastAI
    alias Lumainus.VastAI.Instances
    alias Lumainus.Docling.VastAI.InstanceManager
    alias Lumainus.GPU

    Mix.shell().info("")
    Mix.shell().info("=== Start Vast.ai Instance ===")
    Mix.shell().info("")

    # Get instance to start
    instance_id =
      if specific_id do
        specific_id
      else
        status = InstanceManager.status()

        if status.instance_id do
          status.instance_id
        else
          # Try to find from Vast.ai
          case Instances.list() do
            {:ok, %{"instances" => instances}} when is_list(instances) ->
              stopped =
                Enum.find(instances, fn inst ->
                  inst["actual_status"] == "stopped"
                end)

              if stopped, do: stopped["id"], else: nil

            _ ->
              nil
          end
        end
      end

    if instance_id do
      Mix.shell().info("Starting instance ##{instance_id}...")

      case VastAI.start(instance_id) do
        {:ok, _} ->
          Mix.shell().info("Start command sent.")

          if should_wait do
            Mix.shell().info("Waiting for instance to be ready (timeout: #{timeout_seconds}s)...")

            case wait_for_running(instance_id, timeout_seconds * 1000) do
              {:ok, ip} ->
                Mix.shell().info("")
                Mix.shell().info("Instance is running!")
                Mix.shell().info("  IP: #{ip}")

                # Build endpoint
                endpoint = build_endpoint(ip)
                Mix.shell().info("  Endpoint: #{endpoint}")

                # Update session if exists
                case GPU.get_session_by_instance(instance_id) do
                  nil -> :ok
                  session -> GPU.update_session_status(session, "running")
                end

                # Update InstanceManager
                InstanceManager.set_endpoint(instance_id, endpoint, ip)

                Mix.shell().info("")
                Mix.shell().info("GPU is ready for use!")

              {:error, :timeout} ->
                Mix.shell().error("Timeout waiting for instance to start.")
                Mix.shell().error("Check status with: mix vast_ai.status")
                exit({:shutdown, 1})

              {:error, reason} ->
                Mix.shell().error("Error: #{inspect(reason)}")
                exit({:shutdown, 1})
            end
          else
            Mix.shell().info("Instance starting (not waiting for completion)")
            Mix.shell().info("Check status with: mix vast_ai.status")
          end

        {:error, reason} ->
          Mix.shell().error("Failed to start instance: #{inspect(reason)}")
          exit({:shutdown, 1})
      end
    else
      Mix.shell().error("No stopped instance found to start.")
      Mix.shell().error("")
      Mix.shell().error("If you need to provision a new instance, use:")
      Mix.shell().error("  mix vast_ai.provision")
      exit({:shutdown, 1})
    end

    Mix.shell().info("")
  end

  defp wait_for_running(instance_id, timeout_ms) do
    alias Lumainus.VastAI

    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll_interval = 5_000

    do_wait(instance_id, deadline, poll_interval)
  end

  defp do_wait(instance_id, deadline, poll_interval) do
    if System.monotonic_time(:millisecond) >= deadline do
      {:error, :timeout}
    else
      case Lumainus.VastAI.status(instance_id) do
        {:ok, %{"actual_status" => "running", "public_ipaddr" => ip}}
        when is_binary(ip) and ip != "" ->
          {:ok, ip}

        {:ok, %{"actual_status" => status}} when status in ["running", "loading", "starting"] ->
          Mix.shell().info("  Status: #{status}...")
          Process.sleep(poll_interval)
          do_wait(instance_id, deadline, poll_interval)

        {:ok, %{"actual_status" => "stopped"}} ->
          # Still stopped, keep waiting
          Mix.shell().info("  Status: waiting to start...")
          Process.sleep(poll_interval)
          do_wait(instance_id, deadline, poll_interval)

        {:ok, %{"actual_status" => "exited"}} ->
          {:error, :instance_exited}

        {:error, reason} ->
          {:error, reason}

        _ ->
          Process.sleep(poll_interval)
          do_wait(instance_id, deadline, poll_interval)
      end
    end
  end

  defp build_endpoint(ip) do
    # Try to use HTTPS via Cloudflare if configured
    fqdn =
      (System.get_env("LUMAINUS_DOT_COM_CLOUDFLARE_FQDN") ||
         Lumainus.Cloudflare.cloud_fqdn())
      |> normalize_fqdn()

    if fqdn do
      "https://#{fqdn}"
    else
      "http://#{ip}:#{Lumainus.VastAI.cloud_port()}"
    end
  end

  defp normalize_fqdn(fqdn) do
    case fqdn do
      nil ->
        nil

      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end
    end
  end
end
