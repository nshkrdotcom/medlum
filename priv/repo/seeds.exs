# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# Inside the script, you can read and write to any of your
# repositories directly:
#
#     Lumainus.Repo.insert!(%Lumainus.SomeSchema{})
#
# We recommend using the bang functions (`insert!`, `update!`
# and so on) as they will fail if something goes wrong.

import Ecto.Query

alias Lumainus.Repo
alias Lumainus.Accounts.User

# Create initial system administrator if one doesn't exist
unless Repo.exists?(from(u in User, where: u.role == "system_administrator")) do
  # Create the system administrator
  # Note: This will send a magic link email. In development, check http://localhost:4000/dev/mailbox
  {:ok, admin} =
    Lumainus.Accounts.register_user(%{
      email: "admin@lumainus.local",
      name: "System Administrator"
    })

  # Update role to system_administrator and confirm the user immediately
  admin
  |> Ecto.Changeset.change(%{
    role: "system_administrator",
    confirmed_at: DateTime.utc_now(:second)
  })
  |> Repo.update!()

  IO.puts("""

  ========================================
  Initial System Administrator Created!
  ========================================
  Email: admin@lumainus.local

  To log in:
  1. Start the server: mix phx.server
  2. Visit: http://localhost:4000/users/log-in
  3. Enter the email: admin@lumainus.local
  4. Check the mailbox: http://localhost:4000/dev/mailbox
  5. Click the login link in the email

  After logging in, you can:
  - Access the admin panel: http://localhost:4000/admin/invitations
  - Create invitation links for doctors and other admins
  ========================================
  """)
else
  IO.puts("System administrator already exists. Skipping seed.")
end
