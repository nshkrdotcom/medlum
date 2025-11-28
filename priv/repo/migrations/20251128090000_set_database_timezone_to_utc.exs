defmodule Lumainus.Repo.Migrations.SetDatabaseTimezoneToUtc do
  use Ecto.Migration

  @disable_ddl_transaction true

  def up do
    execute("""
    DO $$
    DECLARE
      db TEXT := current_database();
    BEGIN
      EXECUTE 'ALTER DATABASE ' || quote_ident(db) || ' SET timezone TO ''UTC''';
    END
    $$;
    """)
  end

  def down do
    execute("""
    DO $$
    DECLARE
      db TEXT := current_database();
    BEGIN
      EXECUTE 'ALTER DATABASE ' || quote_ident(db) || ' RESET timezone';
    END
    $$;
    """)
  end
end
