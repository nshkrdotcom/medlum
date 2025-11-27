defmodule Lumainus.Repo.Migrations.AddV2ProfileBackendsToDoclingSettings do
  @moduledoc """
  Adds v2_profile_backends field to docling_settings for configuring
  which backends are used for each processing profile.

  This enables the v2 BackendRouter to read profile->backend mappings
  from the database instead of static config.
  """
  use Ecto.Migration

  def change do
    alter table(:docling_settings) do
      add(:v2_profile_backends, :map,
        default: %{
          "standard" => ["docker_cpu", "local_cpu"],
          "enhanced" => ["docker_gpu", "local_gpu", "cloud"]
        }
      )
    end
  end
end
