defmodule Lumainus.Repo.Migrations.CreateCacheSettings do
  use Ecto.Migration

  @default_system_prompt """
  You are Lumainus, a clinical documentation system.
  Produce structured markdown with inline citations like [doc-001].
  Return JSON that matches the provided schema exactly.
  """

  def up do
    create table(:cache_settings, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      # Cache system prompt - sent with cached context
      add(:system_prompt, :text, null: false, default: @default_system_prompt)

      # Model for cache creation (must support Gemini context caching)
      # Min token limits are model-specific and enforced in application code:
      #   gemini-3.0-pro-preview: 2048
      #   gemini-2.5-pro: 4096
      #   gemini-2.5-flash: 1024
      add(:model, :string, null: false, default: "gemini-2.5-flash")

      # Cache TTL in seconds (default 1 hour)
      add(:ttl_seconds, :integer, null: false, default: 3600)

      # Whether caching is enabled
      add(:enabled, :boolean, null: false, default: true)

      # Singleton constraint
      add(:singleton, :boolean, null: false, default: true)

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:cache_settings, [:singleton]))

    seed_defaults()
  end

  def down do
    drop(table(:cache_settings))
  end

  defp seed_defaults do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    {:ok, uuid} = Ecto.UUID.dump(Ecto.UUID.generate())

    defaults = %{
      id: uuid,
      system_prompt: @default_system_prompt,
      model: "gemini-2.5-flash",
      ttl_seconds: 3600,
      enabled: true,
      singleton: true,
      inserted_at: now,
      updated_at: now
    }

    execute(fn ->
      repo().insert_all("cache_settings", [defaults], on_conflict: :nothing)
    end)
  end
end
