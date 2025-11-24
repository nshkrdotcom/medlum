defmodule Lumainus.VastAI.Instances do
  @moduledoc """
  Instance management wrappers.
  """

  alias Lumainus.VastAI.Client

  def list(opts \\ []), do: Client.get("/instances/", opts)

  def get(instance_id, opts \\ []), do: Client.get("/instances/#{instance_id}/", opts)

  @doc """
  Create instance from an offer.

  Uses PUT /api/v0/asks/{ask_id}/ endpoint.
  The ask_id is the offer's "id" field from search results.
  """
  def create(ask_id, params, opts \\ []) do
    body =
      params
      |> Map.put_new(:client_id, "me")

    Client.put("/asks/#{ask_id}/", body, opts)
  end

  def destroy(instance_id, opts \\ []), do: Client.delete("/instances/#{instance_id}/", opts)

  def start(instance_id, opts \\ []),
    do: Client.put("/instances/#{instance_id}/", %{state: "running"}, opts)

  def stop(instance_id, opts \\ []),
    do: Client.put("/instances/#{instance_id}/", %{state: "stopped"}, opts)

  def wait_for_ready(instance_id, timeout_ms \\ 300_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Stream.repeatedly(fn -> :tick end)
    |> Stream.take_while(fn _ -> System.monotonic_time(:millisecond) < deadline end)
    |> Enum.reduce_while(:waiting, fn _, _ ->
      case get(instance_id) do
        {:ok, %{"actual_status" => "running"} = inst} ->
          {:halt, {:ok, inst}}

        {:ok, %{"actual_status" => "exited"}} ->
          {:halt, {:error, :exited}}

        {:ok, _} ->
          Process.sleep(5_000)
          {:cont, :waiting}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
    |> case do
      :waiting -> {:error, :timeout}
      other -> other
    end
  end
end
