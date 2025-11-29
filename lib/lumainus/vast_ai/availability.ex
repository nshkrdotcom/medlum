defmodule Lumainus.VastAI.Availability do
  @moduledoc """
  Centralized helpers for checking whether Vast.ai is configured and its
  supporting processes are alive. Keeps UI, supervisors, and tests aligned.
  """

  alias Lumainus.Docling.VastAI.{InstanceManager, ProvisioningState}
  alias Lumainus.Docling.VastAI.AutoShutdown

  @spec status() :: map()
  def status do
    enabled = enabled?()

    provisioning_state_alive = process_alive?(ProvisioningState)
    instance_manager_alive = process_alive?(InstanceManager)
    auto_shutdown_alive = process_alive?(AutoShutdown)

    %{
      enabled?: enabled,
      configured?: configured?(),
      provisioning_state_alive?: provisioning_state_alive,
      instance_manager_alive?: instance_manager_alive,
      auto_shutdown_alive?: auto_shutdown_alive,
      operational?: enabled and provisioning_state_alive and instance_manager_alive
    }
  end

  @spec enabled?() :: boolean()
  def enabled? do
    configured?()
  end

  @spec configured?() :: boolean()
  def configured? do
    case Application.get_env(:lumainus, :vast_ai, []) do
      config when is_list(config) ->
        api_key = Keyword.get(config, :api_key)
        is_binary(api_key) and api_key != ""

      _ ->
        false
    end
  end

  @spec operational?() :: boolean()
  def operational? do
    status().operational?
  end

  @spec process_alive?(module()) :: boolean()
  def process_alive?(module) when is_atom(module) do
    case Process.whereis(module) do
      nil -> false
      pid -> Process.alive?(pid)
    end
  end
end
