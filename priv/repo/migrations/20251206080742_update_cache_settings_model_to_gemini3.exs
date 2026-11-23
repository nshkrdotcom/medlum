defmodule Medlum.Repo.Migrations.UpdateCacheSettingsModelToGemini3 do
  use Ecto.Migration

  def up do
    execute("""
    UPDATE cache_settings
    SET model = 'gemini-3-pro-preview'
    WHERE model = 'gemini-2.5-flash'
    """)
  end

  def down do
    execute("""
    UPDATE cache_settings
    SET model = 'gemini-2.5-flash'
    WHERE model = 'gemini-3-pro-preview'
    """)
  end
end
