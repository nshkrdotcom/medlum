defmodule Lumainus.Conversion.TestCase do
  @moduledoc """
  Shared test case for conversion components with Supertester isolation.
  """

  defmacro __using__(opts \\ []) do
    isolation = Keyword.get(opts, :isolation, :full_isolation)

    async? =
      Keyword.get(
        opts,
        :async,
        Supertester.UnifiedTestFoundation.isolation_allows_async?(isolation)
      )

    quote do
      use ExUnit.Case, async: unquote(async?)

      import Supertester.Assertions
      import Supertester.OTPHelpers
      import Supertester.MessageHarness, only: [trace_messages: 2, trace_messages: 3]
      import Lumainus.Conversion.Support.TestHelpers

      setup context do
        Supertester.UnifiedTestFoundation.setup_isolation(unquote(isolation), context)
      end
    end
  end
end
