defmodule Lumainus.LLM.GeminiClient do
  @moduledoc """
  Adapter that routes LLM requests through the `gemini_ex` client library.
  """

  @behaviour Lumainus.LLM.Client

  alias Gemini.Error
  alias Gemini.Types.Content
  alias Gemini.Types.Response.GenerateContentResponse
  require Logger

  @impl true
  def generate_object(model_spec, messages, schema, opts \\ []) do
    with {:ok, contents} <- build_contents(messages),
         {:ok, response} <-
           Gemini.generate(contents, build_options(model_spec, schema, opts)),
         {:ok, text} <- GenerateContentResponse.extract_text(response) do
      {:ok,
       %{
         "object" => decode_object(text),
         "text" => text,
         "usage" => usage_from_response(response)
       }}
    else
      {:error, %Error{} = error} ->
        Logger.error("Gemini client error: #{inspect(error)}")
        {:error, error}

      {:error, reason} ->
        Logger.error("Gemini client failure: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp build_contents(messages) when is_list(messages) and messages != [] do
    contents =
      Enum.map(messages, fn message ->
        role = normalize_role(Map.get(message, :role) || Map.get(message, "role"))
        text = Map.get(message, :content) || Map.get(message, "content") || ""
        Content.text(to_string(text), role)
      end)

    {:ok, contents}
  end

  defp build_contents(_), do: {:error, :invalid_messages}

  defp build_options(model_spec, schema, opts) do
    model = model_from_spec(model_spec)
    cleaned_opts = Keyword.delete(opts, :prompt_context)

    cleaned_opts
    |> Keyword.put(:model, model)
    |> Keyword.put_new(:response_mime_type, "application/json")
    |> maybe_put_schema(schema)
  end

  defp model_from_spec(nil), do: Gemini.Config.default_model()

  defp model_from_spec(model_spec) when is_binary(model_spec) do
    case String.split(model_spec, ":", parts: 2) do
      [_, model] -> model
      [model] -> model
      _ -> Gemini.Config.default_model()
    end
  end

  defp normalize_role(role) when role in [:system, "system"], do: "system"
  defp normalize_role(role) when role in [:user, "user"], do: "user"
  defp normalize_role(_), do: "user"

  defp decode_object(text) do
    case Jason.decode(to_string(text)) do
      {:ok, value} when is_map(value) -> value
      {:ok, other} -> %{"text" => other}
      {:error, _} -> %{"markdown" => text}
    end
  end

  defp usage_from_response(%GenerateContentResponse{usage_metadata: nil}), do: %{}

  defp usage_from_response(%GenerateContentResponse{usage_metadata: usage}) do
    %{
      "total_tokens" => usage.total_token_count,
      "prompt_tokens" => usage.prompt_token_count,
      "completion_tokens" => usage.candidates_token_count
    }
  end

  defp maybe_put_schema(opts, nil), do: opts

  defp maybe_put_schema(opts, schema) when is_map(schema) do
    Keyword.put(opts, :response_schema, schema)
  end
end
