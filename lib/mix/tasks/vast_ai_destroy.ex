defmodule Mix.Tasks.VastAi.Destroy do
  @moduledoc """
  Destroy a Vast.ai GPU instance.

  This is an ADMIN-ONLY operation. It permanently destroys the instance.
  The next time you want to use GPU processing, you'll need to provision again.

  For temporary shutdown (preserving the instance), use `mix vast_ai.stop` instead.

  ## Usage

      mix vast_ai.destroy

  ## Options

    * `--force` - Destroy without confirmation
    * `--all` - Destroy ALL instances (use with caution!)
    * `--id INSTANCE_ID` - Destroy a specific instance

  ## Examples

      # Destroy the current instance
      mix vast_ai.destroy

      # Destroy a specific instance
      mix vast_ai.destroy --id 12345678

      # Force destroy without confirmation
      mix vast_ai.destroy --force

  """
  use Mix.Task

  @shortdoc "Destroy a Vast.ai GPU instance (ADMIN)"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [force: :boolean, all: :boolean, id: :integer],
        aliases: [f: :force, a: :all, i: :id]
      )

    # Start the application
    Mix.Task.run("app.start")

    force = Keyword.get(opts, :force, false)
    destroy_all = Keyword.get(opts, :all, false)
    specific_id = Keyword.get(opts, :id)

    alias Lumainus.VastAI
    alias Lumainus.VastAI.Instances
    alias Lumainus.Docling.VastAI.InstanceManager
    alias Lumainus.GPU

    Mix.shell().info("")
    Mix.shell().info("=== Vast.ai Instance Destruction ===")
    Mix.shell().info("")

    # Get list of instances
    case Instances.list() do
      {:ok, %{"instances" => instances}} when is_list(instances) ->
        active =
          instances
          |> Enum.filter(fn inst ->
            inst["actual_status"] not in ["exited", "destroyed", nil]
          end)
          |> Enum.filter(fn inst ->
            if specific_id do
              inst["id"] == specific_id
            else
              true
            end
          end)

        case active do
          [] ->
            Mix.shell().info("No active instances found.")

            if specific_id do
              Mix.shell().info("Instance ##{specific_id} does not exist or is already destroyed.")
            end

          instances_to_destroy ->
            Mix.shell().info("Found #{length(instances_to_destroy)} instance(s):")
            Mix.shell().info("")

            for inst <- instances_to_destroy do
              Mix.shell().info("  Instance ##{inst["id"]}")
              Mix.shell().info("    Status: #{inst["actual_status"]}")
              Mix.shell().info("    Label: #{inst["label"] || "none"}")
              Mix.shell().info("    GPU: #{inst["gpu_name"] || "?"}")
              Mix.shell().info("    Price: $#{inst["dph_total"] || "?"}/hr")
              Mix.shell().info("")
            end

            proceed =
              if force or destroy_all do
                true
              else
                if length(instances_to_destroy) == 1 do
                  Mix.shell().yes?("Destroy this instance? This cannot be undone.")
                else
                  Mix.shell().yes?(
                    "Destroy ALL #{length(instances_to_destroy)} instances? This cannot be undone."
                  )
                end
              end

            if proceed do
              for inst <- instances_to_destroy do
                instance_id = inst["id"]
                Mix.shell().info("Destroying instance ##{instance_id}...")

                case VastAI.destroy(instance_id) do
                  {:ok, _} ->
                    Mix.shell().info("  Destroyed successfully")

                    # Update session if exists
                    case GPU.get_session_by_instance(instance_id) do
                      nil -> :ok
                      session -> GPU.destroy_session(session, "admin_destroy")
                    end

                  {:error, reason} ->
                    Mix.shell().error("  Failed: #{inspect(reason)}")
                end
              end

              # Clear InstanceManager state
              Mix.shell().info("")
              Mix.shell().info("Clearing InstanceManager state...")
              InstanceManager.clear_state()
              Mix.shell().info("Done.")
            else
              Mix.shell().info("Aborted.")
            end
        end

      {:ok, _} ->
        Mix.shell().info("No instances found.")

      {:error, reason} ->
        Mix.shell().error("Failed to list instances: #{inspect(reason)}")
        exit({:shutdown, 1})
    end

    Mix.shell().info("")
  end
end
