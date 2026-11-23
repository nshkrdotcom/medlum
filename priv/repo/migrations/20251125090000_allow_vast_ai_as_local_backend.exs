defmodule Medlum.Repo.Migrations.AllowVastAiAsLocalBackend do
  @moduledoc """
  Updates the active_local_backend constraint to include vast_ai.

  This allows admins to set vast_ai as the "active backend" which simplifies
  the architecture - users just pick local/cloud and the admin picks which
  backend to use for each mode.
  """

  use Ecto.Migration

  def up do
    # Drop and recreate the constraint with vast_ai included
    execute("ALTER TABLE docling_settings DROP CONSTRAINT IF EXISTS active_local_backend_allowed")

    execute("""
    ALTER TABLE docling_settings
    ADD CONSTRAINT active_local_backend_allowed
    CHECK (active_local_backend IN ('native_cpu', 'native_gpu', 'docker_cpu', 'docker_gpu', 'vast_ai'))
    """)
  end

  def down do
    # Restore original constraint without vast_ai
    execute("ALTER TABLE docling_settings DROP CONSTRAINT IF EXISTS active_local_backend_allowed")

    execute("""
    ALTER TABLE docling_settings
    ADD CONSTRAINT active_local_backend_allowed
    CHECK (active_local_backend IN ('native_cpu', 'native_gpu', 'docker_cpu', 'docker_gpu'))
    """)
  end
end
