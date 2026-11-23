# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# Inside the script, you can read and write to any of your
# repositories directly:
#
#     Medlum.Repo.insert!(%Medlum.SomeSchema{})
#
# We recommend using the bang functions (`insert!`, `update!`
# and so on) as they will fail if something goes wrong.

alias Ecto.Changeset
alias Medlum.Accounts
alias Medlum.Accounts.User
alias Medlum.Repo

admin_email = System.get_env("MEDLUMAI_ADMIN_EMAIL") || "admin@medlumai.local"
admin_name = System.get_env("MEDLUMAI_ADMIN_NAME") || "System Administrator"
admin_password = System.get_env("MEDLUMAI_ADMIN_PASSWORD") || "MedLumAIAdmin!reset"

Repo.transaction(fn ->
  admin =
    case Repo.get_by(User, email: admin_email) do
      nil ->
        {:ok, user} =
          Accounts.register_user(%{
            email: admin_email,
            name: admin_name
          })

        user

      user ->
        user
    end

  admin =
    admin
    |> Changeset.change(%{
      role: "system_administrator",
      confirmed_at: admin.confirmed_at || DateTime.utc_now(:second)
    })
    |> Repo.update!()

  {:ok, {_updated_admin, _tokens}} =
    Accounts.update_user_password(admin, %{password: admin_password})

  IO.puts("""

  ========================================
  System Administrator Ready
  ========================================
  Email: #{admin_email}
  Temp Password: #{admin_password}

  Next steps:
  1. Log in at /users/log-in using the password form.
  2. Visit /users/settings to change the password immediately.
  3. Use /admin/invitations to invite additional users.
  ========================================
  """)
end)
