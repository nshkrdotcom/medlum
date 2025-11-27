{:ok, _} = Application.ensure_all_started(:lumainus)

ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Lumainus.Repo, :manual)
