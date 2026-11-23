defmodule Medlum.Repo.Migrations.CreateDoclingSettings do
  use Ecto.Migration

  @defaults %{
    backend: "local",
    timeout_ms: 1_200_000,
    poll_interval_ms: 5_000,
    local_url: "http://127.0.0.1:8042",
    remote_url: System.get_env("DOCLING_REMOTE_URL")
  }

  def up do
    create table(:docling_settings, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:backend, :string, null: false, default: @defaults.backend)
      add(:local_url, :string, null: false, default: @defaults.local_url)
      add(:remote_url, :string)
      add(:timeout_ms, :integer, null: false, default: @defaults.timeout_ms)
      add(:poll_interval_ms, :integer, null: false, default: @defaults.poll_interval_ms)
      add(:singleton, :boolean, null: false, default: true)

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:docling_settings, [:singleton]))

    create(
      constraint(:docling_settings, :backend_allowed,
        check: "backend IN ('local', 'fast', 'remote', 'vast_ai')"
      )
    )

    seed_defaults()
  end

  def down do
    drop(constraint(:docling_settings, :backend_allowed))
    drop(table(:docling_settings))
  end

  defp seed_defaults do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, uuid} = Ecto.UUID.dump(Ecto.UUID.generate())

    defaults = %{
      id: uuid,
      backend: @defaults.backend,
      local_url: @defaults.local_url,
      remote_url: @defaults.remote_url,
      timeout_ms: @defaults.timeout_ms,
      poll_interval_ms: @defaults.poll_interval_ms,
      singleton: true,
      inserted_at: now,
      updated_at: now
    }

    execute(fn ->
      repo().insert_all("docling_settings", [defaults], on_conflict: :nothing)
    end)
  end
end
