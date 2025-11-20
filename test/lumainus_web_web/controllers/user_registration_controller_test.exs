defmodule LumainusWeb.UserRegistrationControllerTest do
  use LumainusWeb.ConnCase, async: true

  import Lumainus.AccountsFixtures

  alias Lumainus.Accounts

  describe "POST /users/register/:token" do
    test "registers via fallback route when LiveView is unavailable", %{conn: conn} do
      invitation = invitation_fixture(%{email: nil})
      email = unique_user_email()

      conn =
        post(conn, ~p"/users/register/#{invitation.token}", %{
          "user" => %{
            "email" => email,
            "password" => valid_user_password(),
            "name" => "Dr. Fallback"
          }
        })

      assert redirected_to(conn) == ~p"/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Account created successfully"
      assert Accounts.get_user_by_email(email)
    end

    test "registers when invitation requires a fixed email", %{conn: conn} do
      invitation = invitation_fixture(%{email: unique_user_email()})

      conn =
        post(conn, ~p"/users/register/#{invitation.token}", %{
          "user" => %{"password" => valid_user_password(), "name" => "Dr. Invite"}
        })

      assert redirected_to(conn) == ~p"/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Account created successfully"
      assert Accounts.get_user_by_email(invitation.email)
    end

    test "redirects with error for invalid token", %{conn: conn} do
      conn =
        post(conn, ~p"/users/register/invalid", %{
          "user" => %{"email" => unique_user_email(), "password" => valid_user_password()}
        })

      assert redirected_to(conn) == ~p"/users/register"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "Invalid or expired invitation link."
    end

    test "redirects with error for duplicated email", %{conn: conn} do
      user = user_fixture()
      invitation = invitation_fixture(%{email: nil})

      conn =
        post(conn, ~p"/users/register/#{invitation.token}", %{
          "user" => %{"email" => user.email, "password" => valid_user_password()}
        })

      assert redirected_to(conn) == ~p"/users/register/#{invitation.token}"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~
               "#{user.email} has already been taken"
    end

    test "requires form submission payload", %{conn: conn} do
      invitation = invitation_fixture(%{email: unique_user_email()})

      conn = post(conn, ~p"/users/register/#{invitation.token}", %{})

      assert redirected_to(conn) == ~p"/users/register/#{invitation.token}"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "Please submit the registration form to continue."
    end

    test "rejects already used invitation", %{conn: conn} do
      invitation = invitation_fixture(%{email: nil})

      # Consume the invitation
      {:ok, _user} =
        Accounts.use_invitation(invitation, %{
          "email" => unique_user_email(),
          "password" => valid_user_password()
        })

      conn =
        post(conn, ~p"/users/register/#{invitation.token}", %{
          "user" => %{"email" => unique_user_email(), "password" => valid_user_password()}
        })

      assert redirected_to(conn) == ~p"/"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "This invitation has already been used."
    end
  end
end
