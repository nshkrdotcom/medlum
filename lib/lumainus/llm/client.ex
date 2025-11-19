defmodule Lumainus.LLM.Client do
  @moduledoc """
  Behaviour for LLM adapters that generate structured responses for report sections.
  """

  @callback generate_object(String.t(), String.t(), map() | nil, keyword()) ::
              {:ok, map()} | {:error, term()}
end
