defmodule Mix.Tasks.VastAi.Provision do
  @moduledoc """
  Provision a new Vast.ai GPU instance.

  This is an ADMIN-ONLY operation. Regular users can only start/stop
  existing instances from the /reports page.

  ## Usage

      mix vast_ai.provision

  ## Options

    * `--max-price PRICE` - Maximum hourly price (default: 0.18)
    * `--disk GB` - Disk size in GB (default: 20)
    * `--label NAME` - Instance label (default: lumainus-docling)
    * `--dry-run` - Show what would be provisioned without actually doing it

  ## Examples

      # Provision with defaults
      mix vast_ai.provision

      # Provision with custom settings
      mix vast_ai.provision --max-price 0.25 --disk 30

      # Dry run to see available offers
      mix vast_ai.provision --dry-run

  """
  use Mix.Task

  @shortdoc "Provision a new Vast.ai GPU instance (ADMIN)"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [
          max_price: :float,
          disk: :integer,
          label: :string,
          dry_run: :boolean
        ],
        aliases: [p: :max_price, d: :disk, l: :label, n: :dry_run]
      )

    # Start the application
    Mix.Task.run("app.start")

    max_price = Keyword.get(opts, :max_price, 0.18)
    disk_gb = Keyword.get(opts, :disk, 20)
    label = Keyword.get(opts, :label, "lumainus-docling")
    dry_run = Keyword.get(opts, :dry_run, false)

    alias Lumainus.VastAI
    alias Lumainus.VastAI.{Instances, Offers}
    alias Lumainus.Docling.VastAI.InstanceManager

    Mix.shell().info("")
    Mix.shell().info("=== Vast.ai GPU Provisioning ===")
    Mix.shell().info("")

    # Check for existing instances first
    Mix.shell().info("Checking for existing instances...")

    case Instances.list() do
      {:ok, %{"instances" => instances}} when is_list(instances) ->
        active =
          Enum.filter(instances, fn inst ->
            inst["actual_status"] not in ["exited", "destroyed", nil]
          end)

        if length(active) > 0 do
          Mix.shell().error("")
          Mix.shell().error("ERROR: Found #{length(active)} existing instance(s)!")

          for inst <- active do
            Mix.shell().error(
              "  - Instance ##{inst["id"]}: #{inst["actual_status"]} (#{inst["label"]})"
            )
          end

          Mix.shell().error("")
          Mix.shell().error("Destroy existing instances first with: mix vast_ai.destroy")
          exit({:shutdown, 1})
        end

      {:ok, _} ->
        :ok

      {:error, reason} ->
        Mix.shell().error("Failed to check existing instances: #{inspect(reason)}")
        exit({:shutdown, 1})
    end

    Mix.shell().info("No existing instances found.")
    Mix.shell().info("")
    Mix.shell().info("Configuration:")
    Mix.shell().info("  Max price: $#{max_price}/hr")
    Mix.shell().info("  Disk: #{disk_gb} GB")
    Mix.shell().info("  Label: #{label}")
    Mix.shell().info("")

    # Search for offers
    Mix.shell().info("Searching for GPU offers...")

    filters =
      Offers.build_filters(
        gpu_name: "RTX 3090",
        num_gpus: 1,
        verified: true,
        rentable: true,
        geolocation: ["US", "CA"],
        dph_total: {:lte, max_price}
      )

    case Offers.search(filters: filters) do
      {:ok, %{"offers" => [_ | _] = offers}} ->
        sorted = Enum.sort_by(offers, & &1["dph_total"])
        best = List.first(sorted)

        Mix.shell().info("")
        Mix.shell().info("Found #{length(sorted)} offers. Best offer:")
        Mix.shell().info("  Offer ID: #{best["id"]}")
        Mix.shell().info("  Price: $#{best["dph_total"]}/hr")
        Mix.shell().info("  GPU: #{best["gpu_name"]}")
        Mix.shell().info("  Location: #{best["geolocation"]}")
        Mix.shell().info("  Machine: #{best["machine_id"]}")
        Mix.shell().info("")

        if dry_run do
          Mix.shell().info("DRY RUN - Would provision from offer ##{best["id"]}")
          Mix.shell().info("")
          Mix.shell().info("Top 5 offers:")

          sorted
          |> Enum.take(5)
          |> Enum.each(fn offer ->
            Mix.shell().info(
              "  ##{offer["id"]}: $#{offer["dph_total"]}/hr - #{offer["gpu_name"]} (#{offer["geolocation"]})"
            )
          end)
        else
          Mix.shell().info("Provisioning instance...")

          case VastAI.provision_with_https(
                 offer_id: best["id"],
                 disk_gb: disk_gb,
                 label: label
               ) do
            {:ok, instance_id, endpoint} ->
              Mix.shell().info("")
              Mix.shell().info("=== PROVISIONING SUCCESSFUL ===")
              Mix.shell().info("")
              Mix.shell().info("Instance ID: #{instance_id}")
              Mix.shell().info("Endpoint: #{endpoint}")
              Mix.shell().info("")
              Mix.shell().info("The instance is now registered with InstanceManager.")
              Mix.shell().info("Users can start/stop it from /reports.")

              # Register with InstanceManager
              InstanceManager.set_endpoint(instance_id, endpoint)

            {:ok, instance_id} ->
              # Fallback without HTTPS
              Mix.shell().info("")
              Mix.shell().info("Instance #{instance_id} created but HTTPS setup may have failed.")
              Mix.shell().info("Check the admin page for status.")

            {:error, reason} ->
              Mix.shell().error("")
              Mix.shell().error("Provisioning failed: #{inspect(reason)}")
              exit({:shutdown, 1})
          end
        end

      {:ok, %{"offers" => []}} ->
        Mix.shell().error("")
        Mix.shell().error("No GPU offers found matching criteria.")
        Mix.shell().error("Try increasing --max-price or check Vast.ai availability.")
        exit({:shutdown, 1})

      {:error, reason} ->
        Mix.shell().error("Failed to search offers: #{inspect(reason)}")
        exit({:shutdown, 1})
    end

    Mix.shell().info("")
    Mix.shell().info("Done.")
  end
end
