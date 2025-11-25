defmodule Lumainus.Repo.Migrations.ExpandDoclingBackends do
  @moduledoc """
  Expands the docling_settings table to support 5 backends:

  Local backends (free):
    - native_cpu (port 8040) - Host Python, CPU
    - native_gpu (port 8041) - Host Python, GPU
    - docker_cpu (port 8042) - Docker, CPU
    - docker_gpu (port 8043) - Docker, GPU

  Cloud backends ($$$):
    - vast_ai (port 8044) - Vast.ai remote GPU

  Users choose "local" or "cloud". Admins configure which local backend is active.
  """

  use Ecto.Migration

  def up do
    # Add new columns for the expanded backend system
    alter table(:docling_settings) do
      # User-facing default mode
      add_if_not_exists(:default_mode, :string, null: false, default: "local")
      # Which local backend is active
      add_if_not_exists(:active_local_backend, :string, null: false, default: "docker_cpu")

      # URLs for all 5 backends
      add_if_not_exists(:native_cpu_url, :string)
      add_if_not_exists(:native_gpu_url, :string)
      add_if_not_exists(:docker_cpu_url, :string)
      add_if_not_exists(:docker_gpu_url, :string)
      add_if_not_exists(:cloud_url, :string)

      # Progress min interval (may not exist in older schemas)
      add_if_not_exists(:progress_min_interval_ms, :integer, default: 50)
    end

    # Add constraints using raw SQL (create_if_not_exists doesn't work with constraints)
    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'default_mode_allowed'
      ) THEN
        ALTER TABLE docling_settings
        ADD CONSTRAINT default_mode_allowed
        CHECK (default_mode IN ('local', 'cloud'));
      END IF;
    END $$;
    """)

    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'active_local_backend_allowed'
      ) THEN
        ALTER TABLE docling_settings
        ADD CONSTRAINT active_local_backend_allowed
        CHECK (active_local_backend IN ('native_cpu', 'native_gpu', 'docker_cpu', 'docker_gpu'));
      END IF;
    END $$;
    """)

    # Update existing backend constraint to include new values
    execute("ALTER TABLE docling_settings DROP CONSTRAINT IF EXISTS backend_allowed")

    execute("""
    ALTER TABLE docling_settings
    ADD CONSTRAINT backend_allowed
    CHECK (backend IN ('local', 'fast', 'remote', 'vast_ai', 'native_cpu', 'native_gpu', 'docker_cpu', 'docker_gpu'))
    """)

    # Migrate existing data: populate new URL fields from legacy fields
    execute("""
    UPDATE docling_settings
    SET
      docker_cpu_url = COALESCE(docker_cpu_url, local_url),
      native_cpu_url = COALESCE(native_cpu_url, 'http://127.0.0.1:8040'),
      native_gpu_url = COALESCE(native_gpu_url, 'http://127.0.0.1:8041'),
      docker_gpu_url = COALESCE(docker_gpu_url, 'http://127.0.0.1:8043'),
      cloud_url = COALESCE(cloud_url, remote_url)
    WHERE docker_cpu_url IS NULL OR native_cpu_url IS NULL
    """)
  end

  def down do
    # Drop new constraints
    execute("ALTER TABLE docling_settings DROP CONSTRAINT IF EXISTS default_mode_allowed")
    execute("ALTER TABLE docling_settings DROP CONSTRAINT IF EXISTS active_local_backend_allowed")

    # Restore original backend constraint
    execute("ALTER TABLE docling_settings DROP CONSTRAINT IF EXISTS backend_allowed")

    execute("""
    ALTER TABLE docling_settings
    ADD CONSTRAINT backend_allowed
    CHECK (backend IN ('local', 'fast', 'remote', 'vast_ai'))
    """)

    # Remove new columns
    alter table(:docling_settings) do
      remove_if_exists(:default_mode, :string)
      remove_if_exists(:active_local_backend, :string)
      remove_if_exists(:native_cpu_url, :string)
      remove_if_exists(:native_gpu_url, :string)
      remove_if_exists(:docker_cpu_url, :string)
      remove_if_exists(:docker_gpu_url, :string)
      remove_if_exists(:cloud_url, :string)
    end
  end
end
