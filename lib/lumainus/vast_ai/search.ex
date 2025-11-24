defmodule Lumainus.VastAI.Search do
  @moduledoc """
  Build Vast.ai search query strings.
  """

  def build_query(opts \\ []) do
    opts
    |> Enum.flat_map(fn
      {:gpu_name, v} -> [format(:gpu_name, v)]
      {:num_gpus, v} -> [format(:num_gpus, v)]
      {:gpu_ram, v} -> [format(:gpu_ram, {">=", v})]
      {:reliability, v} -> [format(:reliability, {">", v})]
      {:verified, v} -> [format(:verified, v)]
      {:rentable, v} -> [format(:rentable, v)]
      {:geolocation, list} when is_list(list) -> [format(:geolocation, {:in, list})]
      {:dph_total, {:lt, v}} -> [format(:dph_total, {"<", v})]
      {:cuda_vers, v} -> [format(:cuda_vers, {">=", v})]
      {:datacenter, v} -> [format(:datacenter, v)]
      _ -> []
    end)
    |> Enum.join(" ")
  end

  defp format(key, {:in, list}) do
    values = list |> Enum.map(&format_value/1) |> Enum.join(",")
    "#{key} in [#{values}]"
  end

  defp format(key, {op, value}) do
    "#{key}#{op}#{format_value(value)}"
  end

  defp format(key, value) when is_boolean(value) do
    "#{key}=#{if value, do: "True", else: "False"}"
  end

  defp format(key, value), do: "#{key}=#{format_value(value)}"

  defp format_value(v) when is_binary(v), do: String.replace(v, " ", "_")
  defp format_value(v), do: v
end
