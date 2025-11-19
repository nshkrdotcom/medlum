defmodule LumainusWeb.Admin.InvitationsLive do
  use LumainusWeb, :live_view

  alias Lumainus.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-6">
      <div class="mb-8">
        <h1 class="text-3xl font-bold text-gray-900">Invitation Management</h1>
        <p class="mt-2 text-sm text-gray-600">
          Create and manage invitation links for new users
        </p>
      </div>

      <div class="bg-white shadow-sm rounded-lg p-6 mb-8">
        <h2 class="text-xl font-semibold mb-4">Create New Invitation</h2>

        <.form for={@form} phx-submit="create_invitation" class="space-y-4">
          <.input
            type="select"
            name="role"
            label="Role"
            prompt="Select a role"
            options={[
              {"Doctor", "doctor"},
              {"Administrator", "admin"},
              {"System Administrator", "system_administrator"}
            ]}
            required
          />

          <div>
            <.input
              type="email"
              name="email"
              label="Email (Optional)"
              placeholder="user@example.com"
            />
            <p class="mt-1 text-sm text-gray-500">
              If provided, this email will be pre-filled in the registration form
            </p>
          </div>

          <.button type="submit" class="btn btn-primary">
            Generate Invitation Link
          </.button>
        </.form>
      </div>

      <div class="bg-white shadow-sm rounded-lg p-6">
        <h2 class="text-xl font-semibold mb-4">Existing Invitations</h2>

        <div class="space-y-4">
          <%= for invitation <- @invitations do %>
            <div class="border border-gray-200 rounded-lg p-4">
              <div class="flex items-start justify-between">
                <div class="flex-1">
                  <div class="flex items-center gap-3 mb-2">
                    <span class="inline-flex items-center rounded-full bg-blue-100 px-3 py-1 text-sm font-medium text-blue-800">
                      {humanize_role(invitation.role)}
                    </span>

                    <%= if invitation.used_at do %>
                      <span class="inline-flex items-center rounded-full bg-gray-100 px-3 py-1 text-sm font-medium text-gray-800">
                        Used
                      </span>
                    <% else %>
                      <span class="inline-flex items-center rounded-full bg-green-100 px-3 py-1 text-sm font-medium text-green-800">
                        Available
                      </span>
                    <% end %>
                  </div>

                  <%= if invitation.email do %>
                    <p class="text-sm text-gray-600 mb-2">
                      Email: {invitation.email}
                    </p>
                  <% end %>

                  <p class="text-xs text-gray-500 mb-2">
                    Created: {Calendar.strftime(invitation.inserted_at, "%B %d, %Y at %I:%M %p")}
                    <%= if invitation.created_by do %>
                      by {invitation.created_by.email}
                    <% end %>
                  </p>

                  <%= if invitation.used_at do %>
                    <p class="text-xs text-gray-500">
                      Used: {Calendar.strftime(invitation.used_at, "%B %d, %Y at %I:%M %p")}
                    </p>
                  <% else %>
                    <div class="mt-3">
                      <label class="block text-xs font-medium text-gray-700 mb-1">
                        Invitation Link:
                      </label>
                      <div class="flex gap-2">
                        <input
                          type="text"
                          readonly
                          value={invitation_url(invitation.token)}
                          class="flex-1 text-sm rounded-md border-gray-300 bg-gray-50 font-mono"
                          id={"invitation-link-#{invitation.id}"}
                        />
                        <button
                          type="button"
                          phx-click="copy_link"
                          phx-value-token={invitation.token}
                          id={"copy-invitation-#{invitation.id}"}
                          phx-hook="CopyInvitationLink"
                          data-target-input-id={"invitation-link-#{invitation.id}"}
                          class="px-3 py-2 text-sm font-medium text-gray-700 bg-white border border-gray-300 rounded-md hover:bg-gray-50"
                        >
                          Copy
                        </button>
                      </div>
                    </div>
                  <% end %>
                </div>

                <%= if !invitation.used_at do %>
                  <button
                    type="button"
                    phx-click="delete_invitation"
                    phx-value-id={invitation.id}
                    data-confirm="Are you sure you want to delete this invitation?"
                    class="ml-4 text-red-600 hover:text-red-800 text-sm font-medium"
                  >
                    Delete
                  </button>
                <% end %>
              </div>
            </div>
          <% end %>

          <%= if @invitations == [] do %>
            <p class="text-center text-gray-500 py-8">
              No invitations created yet. Create one above to get started.
            </p>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    invitations = Accounts.list_invitations()

    {:ok,
     socket
     |> assign(invitations: invitations, form: to_form(%{}))}
  end

  @impl true
  def handle_event("create_invitation", %{"role" => role} = params, socket) do
    email = if params["email"] && params["email"] != "", do: params["email"], else: nil

    case Accounts.create_invitation(
           %{role: role, email: email},
           socket.assigns.current_scope.user
         ) do
      {:ok, _invitation} ->
        invitations = Accounts.list_invitations()

        {:noreply,
         socket
         |> put_flash(:info, "Invitation created successfully!")
         |> assign(invitations: invitations)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to create invitation")}
    end
  end

  def handle_event("copy_link", %{"token" => _token}, socket) do
    # The actual copying happens in the client-side JS
    # This event is just for feedback
    {:noreply, put_flash(socket, :info, "Invitation link copied to clipboard!")}
  end

  def handle_event("delete_invitation", %{"id" => id}, socket) do
    invitation = Enum.find(socket.assigns.invitations, &(&1.id == String.to_integer(id)))

    if invitation do
      case Accounts.delete_invitation(invitation) do
        {:ok, _} ->
          invitations = Accounts.list_invitations()

          {:noreply,
           socket
           |> put_flash(:info, "Invitation deleted successfully")
           |> assign(invitations: invitations)}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to delete invitation")}
      end
    else
      {:noreply, socket}
    end
  end

  defp invitation_url(token) do
    LumainusWeb.Endpoint.url() <> "/users/register/#{token}"
  end

  defp humanize_role("doctor"), do: "Doctor"
  defp humanize_role("admin"), do: "Administrator"
  defp humanize_role("system_administrator"), do: "System Administrator"
  defp humanize_role(role), do: role
end
