defmodule Medlum.Repo do
  use Ecto.Repo,
    otp_app: :medlum,
    adapter: Ecto.Adapters.Postgres
end
