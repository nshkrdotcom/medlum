defmodule LumainusWeb.UserRegistrationController do
  use LumainusWeb, :controller

  alias Lumainus.Accounts
  alias LumainusWeb.CoreComponents

  def create(conn, %{"token" => token} = params) do
    case Accounts.get_invitation_by_token(token) do
      nil ->
        conn
        |> put_flash(:error, "Invalid or expired invitation link.")
        |> redirect(to: ~p"/users/register")

      invitation ->
        user_params = Map.get(params, "user", %{})

        if map_size(user_params) == 0 do
          conn
          |> put_flash(:error, "Please submit the registration form to continue.")
          |> redirect(to: ~p"/users/register/#{invitation.token}")
        else
          maybe_register_with_invitation(conn, invitation, user_params)
        end
    end
  end

  def create(conn, _params) do
    conn
    |> put_flash(:error, "Registration requires a valid invitation link.")
    |> redirect(to: ~p"/users/register")
  end

  defp maybe_register_with_invitation(conn, invitation, user_params) do
    case Accounts.use_invitation(invitation, user_params) do
      {:ok, user} ->
        {:ok, _} = Accounts.deliver_login_instructions(user, &url(~p"/users/log-in/#{&1}"))

        conn
        |> put_flash(:info, success_message(user))
        |> redirect(to: ~p"/users/log-in")

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_flash(:error, format_changeset_errors(changeset))
        |> redirect(to: ~p"/users/register/#{invitation.token}")

      {:error, :invitation_already_used} ->
        conn
        |> put_flash(:error, "This invitation has already been used.")
        |> redirect(to: ~p"/")
    end
  end

  defp format_changeset_errors(%Ecto.Changeset{errors: errors}) do
    errors
    |> Enum.map(fn {field, error} ->
      message = CoreComponents.translate_error(error)
      human_field = field |> Phoenix.Naming.humanize() |> String.capitalize()
      human_field <> " " <> message
    end)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> "Account could not be created. Please review the form and try again."
      messages -> Enum.join(messages, ". ")
    end
  end

  defp success_message(user) do
    "Account created successfully as #{humanize_role(user.role)}! " <>
      "An email was sent to #{user.email}, please access it to confirm your account."
  end

  defp humanize_role("doctor"), do: "Doctor"
  defp humanize_role("admin"), do: "Administrator"
  defp humanize_role("system_administrator"), do: "System Administrator"
  defp humanize_role(role), do: role
end
