defmodule Lumainus.DataCase do
  @moduledoc """
  This module sets up helpers for tests that interact with the data layer.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias Lumainus.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Lumainus.DataCase
    end
  end

  setup tags do
    Lumainus.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc """
  Checkout a sandbox connection and, unless tests run asynchronously, share it.
  """
  def setup_sandbox(tags) do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Lumainus.Repo)

    unless tags[:async] do
      Ecto.Adapters.SQL.Sandbox.mode(Lumainus.Repo, {:shared, self()})
    end
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.
  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", inspect(value))
      end)
    end)
  end
end
