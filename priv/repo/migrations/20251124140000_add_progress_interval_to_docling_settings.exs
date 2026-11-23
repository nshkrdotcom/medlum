defmodule Medlum.Repo.Migrations.AddProgressIntervalToDoclingSettings do
  use Ecto.Migration

  @default_poll 250
  @default_progress_min 50

  def up do
    alter table(:docling_settings) do
      modify(:poll_interval_ms, :integer, null: false, default: @default_poll)
      add(:progress_min_interval_ms, :integer, null: false, default: @default_progress_min)
    end

    execute(
      "UPDATE docling_settings SET poll_interval_ms = #{@default_poll}, progress_min_interval_ms = #{@default_progress_min}"
    )
  end

  def down do
    alter table(:docling_settings) do
      modify(:poll_interval_ms, :integer, null: false, default: 5_000)
      remove(:progress_min_interval_ms)
    end

    execute("UPDATE docling_settings SET poll_interval_ms = 5000")
  end
end
