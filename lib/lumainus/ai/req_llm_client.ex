defmodule Lumainus.AI.ReqLLMClient do
  @behaviour Lumainus.AI.Client

  require Logger

  @impl true
  def generate_object(model_spec, context, schema, opts \\ []) do
    ReqLLM.generate_object(model_spec, context, schema, opts)
  rescue
    error ->
      Logger.error("ReqLLM generate_object failure: #{Exception.message(error)}")
      {:error, error}
  end
end
