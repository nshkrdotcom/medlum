defmodule LumainusWeb.UserSessionController do
  use LumainusWeb, :controller

  alias Lumainus.Accounts
  alias LumainusWeb.UserAuth

  def create(conn, %{"_action" => "confirmed"} = params) do
    create(conn, params, "User confirmed successfully.")
  end

  def create(conn, params) do
    create(conn, params, "Welcome back!")
  end

  # magic link login
  defp create(conn, %{"user" => %{"token" => token} = user_params}, info) do
    case Accounts.login_user_by_magic_link(token) do
      {:ok, {user, tokens_to_disconnect}} ->
        UserAuth.disconnect_sessions(tokens_to_disconnect)
        maybe_update_timezone(conn, user, user_params)

        conn
        |> put_flash(:info, info)
        |> UserAuth.log_in_user(user, user_params)

      _ ->
        conn
        |> put_flash(:error, "The link is invalid or it has expired.")
        |> redirect(to: ~p"/users/log-in")
    end
  end

  # email + password login
  defp create(conn, %{"user" => user_params}, info) do
    %{"email" => email, "password" => password} = user_params

    if user = Accounts.get_user_by_email_and_password(email, password) do
      maybe_update_timezone(conn, user, user_params)

      conn
      |> put_flash(:info, info)
      |> UserAuth.log_in_user(user, user_params)
    else
      # In order to prevent user enumeration attacks, don't disclose whether the email is registered.
      conn
      |> put_flash(:error, "Invalid email or password")
      |> put_flash(:email, String.slice(email, 0, 160))
      |> redirect(to: ~p"/users/log-in")
    end
  end

  # Update user's timezone from browser detection if provided and valid
  # Checks form params first (password login), then cookie (magic link login)
  defp maybe_update_timezone(conn, user, user_params) do
    tz = get_timezone_from_params_or_cookie(conn, user_params)

    require Logger

    Logger.info(
      "[Login] Timezone detection - params: #{inspect(user_params["timezone"])}, cookie: #{inspect(conn.cookies["browser_timezone"])}, resolved: #{inspect(tz)}"
    )

    if tz && tz in Tzdata.zone_list() do
      Logger.info("[Login] Updating user #{user.id} timezone to: #{tz}")
      Accounts.update_user_timezone(user, tz)
    end
  end

  defp get_timezone_from_params_or_cookie(_conn, %{"timezone" => tz})
       when is_binary(tz) and tz != "" do
    tz
  end

  defp get_timezone_from_params_or_cookie(conn, _params) do
    # Fallback to cookie (set by JS on login page, used for magic link login)
    # Cookie value is URL-encoded, so decode it
    case conn.cookies["browser_timezone"] do
      nil -> nil
      encoded -> URI.decode(encoded)
    end
  end

  def update_password(conn, %{"user" => user_params} = params) do
    user = conn.assigns.current_scope.user
    true = Accounts.sudo_mode?(user)
    {:ok, {_user, expired_tokens}} = Accounts.update_user_password(user, user_params)

    # disconnect all existing LiveViews with old sessions
    UserAuth.disconnect_sessions(expired_tokens)

    conn
    |> put_session(:user_return_to, ~p"/users/settings")
    |> create(params, "Password updated successfully!")
  end

  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Logged out successfully.")
    |> UserAuth.log_out_user()
  end
end
