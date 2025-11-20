defmodule LumainusWeb.UserLive.Registration do
  use LumainusWeb, :live_view

  alias Lumainus.Accounts
  alias Lumainus.Accounts.User

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-sm">
        <div class="text-center">
          <.header>
            <%= if @invitation do %>
              Register as {humanize_role(@invitation.role)}
            <% else %>
              Register for an account
            <% end %>
            <:subtitle>
              <%= if @invitation do %>
                You've been invited to join as a {humanize_role(@invitation.role)}.
              <% else %>
                Already registered?
                <.link navigate={~p"/users/log-in"} class="font-semibold text-brand hover:underline">
                  Log in
                </.link>
                to your account now.
              <% end %>
            </:subtitle>
          </.header>
        </div>

        <.form
          :if={@invitation}
          for={@form}
          id="registration_form"
          action={~p"/users/register/#{@invitation.token}"}
          method="post"
          phx-submit="save"
          phx-change="validate"
        >
          <input
            :if={@invitation.email}
            type="hidden"
            name={@form[:email].name}
            value={@invitation.email}
          />
          <.input
            field={@form[:name]}
            type="text"
            label="Full Name"
            autocomplete="name"
            required
            phx-mounted={JS.focus()}
          />

          <.input
            field={@form[:email]}
            type="email"
            label="Email"
            autocomplete="username"
            required
            disabled={@invitation.email != nil}
          />

          <.input
            field={@form[:password]}
            type="password"
            label="Password"
            autocomplete="new-password"
            required
          />

          <.button phx-disable-with="Creating account..." class="btn btn-primary w-full">
            Create an account
          </.button>
        </.form>

        <div :if={!@invitation} class="text-center mt-4">
          <p class="text-sm text-gray-600">
            Registration requires an invitation. Please contact an administrator for an invitation link.
          </p>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, %{assigns: %{current_scope: %{user: user}}} = socket)
      when not is_nil(user) do
    {:ok, redirect(socket, to: LumainusWeb.UserAuth.signed_in_path(socket))}
  end

  def mount(%{"token" => token}, _session, socket) do
    case Accounts.get_invitation_by_token(token) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Invalid or expired invitation link.")
         |> assign(invitation: nil, form: nil)}

      invitation ->
        if Lumainus.Accounts.Invitation.valid?(invitation) do
          changeset =
            Accounts.change_user_email(%User{}, %{email: invitation.email || ""},
              validate_unique: false
            )

          {:ok,
           socket
           |> assign(invitation: invitation)
           |> assign_form(changeset), temporary_assigns: [form: nil]}
        else
          {:ok,
           socket
           |> put_flash(:error, "This invitation has already been used.")
           |> assign(invitation: nil, form: nil)}
        end
    end
  end

  def mount(_params, _session, socket) do
    {:ok, assign(socket, invitation: nil, form: nil)}
  end

  @impl true
  def handle_event(
        "save",
        %{"user" => user_params},
        %{assigns: %{invitation: invitation}} = socket
      )
      when not is_nil(invitation) do
    case Accounts.use_invitation(invitation, user_params) do
      {:ok, user} ->
        {:ok, _} =
          Accounts.deliver_login_instructions(
            user,
            &url(~p"/users/log-in/#{&1}")
          )

        {:noreply,
         socket
         |> put_flash(
           :info,
           "Account created successfully as #{humanize_role(user.role)}! An email was sent to #{user.email}, please access it to confirm your account."
         )
         |> push_navigate(to: ~p"/users/log-in")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}

      {:error, :invitation_already_used} ->
        {:noreply,
         socket
         |> put_flash(:error, "This invitation has already been used.")
         |> push_navigate(to: ~p"/")}
    end
  end

  def handle_event("save", _params, socket) do
    {:noreply, put_flash(socket, :error, "Registration requires a valid invitation.")}
  end

  def handle_event("validate", %{"user" => user_params}, socket) do
    changeset = Accounts.change_user_email(%User{}, user_params, validate_unique: false)
    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    form = to_form(changeset, as: "user")
    assign(socket, form: form)
  end

  defp humanize_role("doctor"), do: "Doctor"
  defp humanize_role("admin"), do: "Administrator"
  defp humanize_role("system_administrator"), do: "System Administrator"
  defp humanize_role(role), do: role
end
