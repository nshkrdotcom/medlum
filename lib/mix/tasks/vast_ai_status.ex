defmodule Mix.Tasks.VastAi.Status do
  @moduledoc """
  Show the current status of Vast.ai GPU instances.

  ## Usage

      mix vast_ai.status

  ## Options

    * `--json` - Output as JSON (for scripting)
    * `--verbose` - Show detailed information

  ## Examples

      mix vast_ai.status
      mix vast_ai.status --verbose
      mix vast_ai.status --json

  """
  use Mix.Task

  @shortdoc "Show Vast.ai GPU instance status"

  @impl true
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [json: :boolean, verbose: :boolean],
        aliases: [j: :json, v: :verbose]
      )

    # Start the application
    Mix.Task.run("app.start", [])

    json_output = Keyword.get(opts, :json, false)
    verbose = Keyword.get(opts, :verbose, false)

    alias Lumainus.VastAI.Instances
    alias Lumainus.Docling.VastAI.{InstanceManager, ActivityTracker, AutoShutdown}

    # Get local state
    local_status = InstanceManager.status()
    activity = ActivityTracker.status()
    auto_shutdown = AutoShutdown.status()

    # Get remote state from Vast.ai
    remote_instances =
      case Instances.list() do
        {:ok, %{"instances" => instances}} when is_list(instances) ->
          Enum.filter(instances, fn inst ->
            inst["actual_status"] not in ["exited", "destroyed", nil]
          end)

        _ ->
          []
      end

    if json_output do
      output = %{
        local: %{
          status: local_status.status,
          instance_id: local_status.instance_id,
          endpoint: local_status.endpoint
        },
        activity: %{
          last_activity: activity.last_activity,
          idle_minutes: activity.idle_minutes,
          idle_formatted: activity.idle_formatted
        },
        auto_shutdown: %{
          enabled: auto_shutdown.enabled,
          idle_timeout_minutes: auto_shutdown.idle_timeout_minutes,
          instances_stopped: auto_shutdown.instances_stopped
        },
        remote_instances:
          Enum.map(remote_instances, fn inst ->
            %{
              id: inst["id"],
              status: inst["actual_status"],
              label: inst["label"],
              gpu: inst["gpu_name"],
              price: inst["dph_total"],
              ip: inst["public_ipaddr"]
            }
          end)
      }

      IO.puts(Jason.encode!(output, pretty: true))
    else
      Mix.shell().info("")
      Mix.shell().info("=== Vast.ai GPU Status ===")
      Mix.shell().info("")

      # Local state
      Mix.shell().info("Local State (InstanceManager):")
      Mix.shell().info("  Status: #{format_status(local_status.status)}")
      Mix.shell().info("  Instance ID: #{local_status.instance_id || "none"}")
      Mix.shell().info("  Endpoint: #{local_status.endpoint || "none"}")
      Mix.shell().info("")

      # Activity
      Mix.shell().info("Activity Tracking:")
      Mix.shell().info("  Last activity: #{activity.idle_formatted}")

      if activity.idle_minutes != :never do
        Mix.shell().info("  Idle for: #{activity.idle_minutes} minutes")
      end

      Mix.shell().info("")

      # Auto-shutdown
      Mix.shell().info("Auto-Shutdown:")
      Mix.shell().info("  Enabled: #{auto_shutdown.enabled}")
      Mix.shell().info("  Idle timeout: #{auto_shutdown.idle_timeout_minutes} minutes")
      Mix.shell().info("  Check interval: #{auto_shutdown.check_interval_minutes} minutes")
      Mix.shell().info("  Instances stopped: #{auto_shutdown.instances_stopped}")
      Mix.shell().info("")

      # Remote instances
      Mix.shell().info("Vast.ai Instances:")

      case remote_instances do
        [] ->
          Mix.shell().info("  No active instances on Vast.ai")

        instances ->
          for inst <- instances do
            Mix.shell().info("")
            Mix.shell().info("  Instance ##{inst["id"]}:")
            Mix.shell().info("    Status: #{inst["actual_status"]}")
            Mix.shell().info("    Label: #{inst["label"] || "none"}")
            Mix.shell().info("    GPU: #{inst["gpu_name"] || "?"}")
            Mix.shell().info("    Price: $#{inst["dph_total"] || "?"}/hr")

            if inst["public_ipaddr"] do
              Mix.shell().info("    IP: #{inst["public_ipaddr"]}")
            end

            if verbose do
              Mix.shell().info("    Machine ID: #{inst["machine_id"]}")
              Mix.shell().info("    Location: #{inst["geolocation"]}")

              if inst["ssh_host"] do
                Mix.shell().info("    SSH: ssh -p #{inst["ssh_port"]} root@#{inst["ssh_host"]}")
              end
            end
          end
      end

      Mix.shell().info("")
    end
  end

  defp format_status(:running), do: "RUNNING (ready for use)"
  defp format_status(:stopped), do: "STOPPED (can be started quickly)"
  defp format_status(:loading), do: "LOADING (starting up)"
  defp format_status(:no_instance), do: "NO INSTANCE (needs provisioning)"
  defp format_status(:none), do: "NO INSTANCE (needs provisioning)"
  defp format_status(status), do: "#{status}"
end
