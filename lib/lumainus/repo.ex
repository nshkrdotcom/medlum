defmodule Lumainus.Repo do
  use Ecto.Repo,
    otp_app: :lumainus,
    adapter: Ecto.Adapters.Postgres
end
