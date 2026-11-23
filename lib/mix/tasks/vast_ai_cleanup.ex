defmodule Mix.Tasks.VastAi.Cleanup do
  @moduledoc """
  Checks for idle Vast.ai instances and destroys them if idle too long.

  This can be run from crontab for external scheduling:

      # Every 5 minutes
      */5 * * * * cd /path/to/medlum && mix vast_ai.cleanup

  Or for production releases:

      # Using release command
      */5 * * * * cd /path/to/medlum && bin/medlum eval "Medlum.Docling.VastAI.AutoShutdown.check_and_shutdown()"

  ## Options

    * `--force` - Destroy instance even if not idle (use with caution!)
    * `--dry-run` - Check but don't actually destroy
    * `--timeout MINUTES` - Override idle timeout from config

  ## Examples

      # Normal check
      mix vast_ai.cleanup

      # Check with custom timeout
      mix vast_ai.cleanup --timeout 30

      # Dry run to see what would happen
      mix vast_ai.cleanup --dry-run

  """
  use Mix.Task

  @shortdoc "Check and destroy idle Vast.ai GPU instances"

  @impl true
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [force: :boolean, dry_run: :boolean, timeout: :integer],
        aliases: [f: :force, n: :dry_run, t: :timeout]
      )

    # Start the application
    Mix.Task.run("app.start", [])

    dry_run = Keyword.get(opts, :dry_run, false)
    force = Keyword.get(opts, :force, false)
    timeout_override = Keyword.get(opts, :timeout)

    if dry_run do
      Mix.shell().info("DRY RUN - No instances will be destroyed")
    end

    # Get status
    alias Medlum.Docling.VastAI.{ActivityTracker, AutoShutdown}
    alias Medlum.VastAI.Instances

    activity = ActivityTracker.status()
    config_timeout = AutoShutdown.idle_timeout_minutes()
    timeout = timeout_override || config_timeout

    Mix.shell().info("")
    Mix.shell().info("=== Vast.ai Cleanup Check ===")
    Mix.shell().info("Idle timeout: #{timeout} minutes")
    Mix.shell().info("Last activity: #{activity.idle_formatted}")
    Mix.shell().info("")

    case Instances.list() do
      {:ok, %{"instances" => instances}} ->
        running =
          Enum.filter(instances, fn inst ->
            inst["actual_status"] in ["running", "loading"]
          end)

        case running do
          [] ->
            Mix.shell().info("No running instances found.")

          instances ->
            for inst <- instances do
              instance_id = inst["id"]
              status = inst["actual_status"]

              Mix.shell().info("Instance ##{instance_id} [#{status}]")

              should_destroy =
                cond do
                  force ->
                    Mix.shell().info("  Force flag set, will destroy")
                    true

                  activity.idle_minutes == :never ->
                    Mix.shell().info("  No activity recorded, will destroy")
                    true

                  activity.idle_minutes >= timeout ->
                    Mix.shell().info(
                      "  Idle for #{activity.idle_minutes} min (>= #{timeout}), will destroy"
                    )

                    true

                  true ->
                    Mix.shell().info(
                      "  Idle for #{activity.idle_minutes} min (< #{timeout}), keeping"
                    )

                    false
                end

              if should_destroy and not dry_run do
                Mix.shell().info("  Destroying instance...")

                case Medlum.VastAI.destroy(instance_id) do
                  {:ok, _} ->
                    Mix.shell().info("  ✓ Destroyed successfully")

                  {:error, reason} ->
                    Mix.shell().error("  ✗ Failed to destroy: #{inspect(reason)}")
                end
              end
            end
        end

      {:error, reason} ->
        Mix.shell().error("Failed to list instances: #{inspect(reason)}")
        exit({:shutdown, 1})
    end

    Mix.shell().info("")
    Mix.shell().info("Done.")
  end
end
