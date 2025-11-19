defmodule Lumainus.LLM.GeminiClient do
  @moduledoc """
  Adapter that routes LLM requests through ReqLLM, which in turn speaks to the Gemini backend.
  """

  @behaviour Lumainus.LLM.Client

  @compile {:no_warn_undefined, ReqLLM}
  @compile {:no_warn_undefined, ReqLLM.Response}

  alias ReqLLM.Response
  require Logger

  @impl true
  def generate_object(model_spec, messages, schema, opts \\ []) do
    req_opts = normalize_options(opts)
    schema = schema || %{}

    case ReqLLM.generate_object(model_spec, messages, schema, req_opts) do
      {:ok, response} ->
        {:ok,
         %{
           "object" => Response.object(response) || %{},
           "text" => Response.text(response),
           "usage" => Response.usage(response)
         }}

      {:error, error} ->
        Logger.error("ReqLLM client error: #{inspect(error)}")
        {:error, error}
    end
  end

  defp normalize_options(opts) do
    opts
    |> Keyword.delete(:prompt_context)
    |> rename_key(:max_output_tokens, :max_tokens)
  end

  defp rename_key(opts, old_key, new_key) do
    case Keyword.pop(opts, old_key) do
      {nil, remaining} -> remaining
      {value, remaining} -> Keyword.put(remaining, new_key, value)
    end
  end
end
