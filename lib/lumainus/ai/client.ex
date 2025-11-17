defmodule Lumainus.AI.Client do
  @callback generate_object(String.t(), any(), keyword(), keyword()) ::
              {:ok, map()} | {:error, term()}
end
