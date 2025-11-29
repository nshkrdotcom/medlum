defmodule Mix.Tasks.VastAi.Stop do
  @moduledoc """
  Stop a running Vast.ai GPU instance.

  This preserves the instance so it can be started quickly later.
  The instance will cost minimal fees while stopped (only disk storage).

  For permanent destruction, use `mix vast_ai.destroy` instead.

  ## Usage

      mix vast_ai.stop

  ## Options

    * `--id INSTANCE_ID` - Stop a specific instance

  ## Examples

      mix vast_ai.stop
      mix vast_ai.stop --id 12345678

  """
  use Mix.Task

  @shortdoc "Stop a running Vast.ai GPU instance (preserves it)"

  @impl true
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [id: :integer],
        aliases: [i: :id]
      )

    # Start the application
    Mix.Task.run("app.start", [])

    specific_id = Keyword.get(opts, :id)

    alias Lumainus.VastAI
    alias Lumainus.VastAI.Instances
    alias Lumainus.Docling.VastAI.InstanceManager
    alias Lumainus.GPU

    Mix.shell().info("")
    Mix.shell().info("=== Stop Vast.ai Instance ===")
    Mix.shell().info("")

    # Get instance to stop
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
              running =
                Enum.find(instances, fn inst ->
                  inst["actual_status"] == "running"
                end)

              if running, do: running["id"], else: nil

            _ ->
              nil
          end
        end
      end

    if instance_id do
      Mix.shell().info("Stopping instance ##{instance_id}...")

      case VastAI.stop(instance_id) do
        {:ok, _} ->
          Mix.shell().info("Instance stopped successfully.")
          Mix.shell().info("")
          Mix.shell().info("The instance is preserved and can be started quickly with:")
          Mix.shell().info("  mix vast_ai.start")
          Mix.shell().info("")
          Mix.shell().info("Or users can start it from the /reports page.")

          # Update session if exists
          case GPU.get_session_by_instance(instance_id) do
            nil -> :ok
            session -> GPU.update_session_status(session, "stopped")
          end

          # Update InstanceManager
          InstanceManager.set_stopped(instance_id)

        {:error, reason} ->
          Mix.shell().error("Failed to stop instance: #{inspect(reason)}")
          exit({:shutdown, 1})
      end
    else
      Mix.shell().info("No running instance found to stop.")
    end

    Mix.shell().info("")
  end
end
