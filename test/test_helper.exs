{:ok, _} = Application.ensure_all_started(:medlum)

ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Medlum.Repo, :manual)
