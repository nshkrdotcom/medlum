defmodule LumainusWeb.Admin.InvitationsLive do
  use LumainusWeb, :live_view

  alias Lumainus.Accounts
  alias LumainusWeb.CoreComponents

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-6">
      <div class="mb-8">
        <h1 class="text-3xl font-bold text-gray-900 dark:text-gray-100">Invitation Management</h1>
        <p class="mt-2 text-sm text-gray-600 dark:text-gray-300">
          Create and manage invitation links for new users
        </p>
      </div>

      <div class="bg-white dark:bg-gray-800 shadow-sm rounded-lg p-6 mb-4">
        <div class="flex items-center justify-between">
          <div>
            <p class="text-sm font-medium text-slate-600 dark:text-slate-300">
              Docling ingestion service
            </p>
            <p class="text-xs text-slate-500 dark:text-slate-400">
              Last check: {docling_check_timestamp(@docling_health, @locale, @timezone)}
            </p>
          </div>
          <span class={docling_status_badge_class(@docling_health)}>
            {docling_status_label(@docling_health)}
          </span>
        </div>
        <p class="mt-3 text-sm text-slate-600 dark:text-slate-300">
          {docling_status_message(@docling_health)}
        </p>
      </div>

      <div class="bg-white dark:bg-gray-800 shadow-sm rounded-lg p-6 mb-8">
        <h2 class="text-xl font-semibold mb-4 text-gray-900 dark:text-gray-100">
          Create New Invitation
        </h2>

        <.form for={@form} phx-submit="create_invitation" class="space-y-4">
          <.input
            type="select"
            name="role"
            label="Role"
            prompt="Select a role"
            value="doctor"
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
              value={nil}
              placeholder="user@example.com"
            />
            <p class="mt-1 text-sm text-gray-500 dark:text-gray-400">
              If provided, this email will be pre-filled in the registration form
            </p>
          </div>

          <.button type="submit" class="btn btn-primary">
            Generate Invitation Link
          </.button>
        </.form>
      </div>

      <div class="bg-white dark:bg-gray-800 shadow-sm rounded-lg p-6">
        <h2 class="text-xl font-semibold mb-4 text-gray-900 dark:text-gray-100">
          Existing Invitations
        </h2>

        <div class="space-y-4">
          <%= for invitation <- @invitations do %>
            <div class="border border-gray-200 dark:border-gray-700 rounded-lg p-4">
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
                    <p class="text-sm text-gray-600 dark:text-gray-300 mb-2">
                      Email: {invitation.email}
                    </p>
                  <% end %>

                  <p class="text-xs text-gray-500 dark:text-gray-400 mb-2">
                    Created: {format_datetime(invitation.inserted_at,
                      locale: @locale,
                      timezone: @timezone,
                      format: :long
                    )}
                    <%= if invitation.created_by do %>
                      by {invitation.created_by.email}
                    <% end %>
                  </p>

                  <%= if invitation.used_at do %>
                    <p class="text-xs text-gray-500 dark:text-gray-400">
                      Used: {format_datetime(invitation.used_at,
                        locale: @locale,
                        timezone: @timezone,
                        format: :long
                      )}
                    </p>
                  <% else %>
                    <div class="mt-3">
                      <label class="block text-xs font-medium text-gray-700 dark:text-gray-200 mb-1">
                        Invitation Link:
                      </label>
                      <div class="flex gap-2">
                        <input
                          type="text"
                          readonly
                          value={invitation_url(invitation.token)}
                          class="flex-1 text-sm rounded-md border-gray-300 dark:border-gray-600 bg-gray-50 dark:bg-gray-700 text-gray-900 dark:text-gray-100 font-mono"
                          id={"invitation-link-#{invitation.id}"}
                        />
                        <button
                          type="button"
                          phx-click="copy_link"
                          phx-value-token={invitation.token}
                          id={"copy-invitation-#{invitation.id}"}
                          phx-hook="CopyInvitationLink"
                          data-target-input-id={"invitation-link-#{invitation.id}"}
                          class="px-3 py-2 text-sm font-medium text-gray-700 dark:text-gray-200 bg-white dark:bg-gray-700 border border-gray-300 dark:border-gray-600 rounded-md hover:bg-gray-50 dark:hover:bg-gray-600"
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
            <p class="text-center text-gray-500 dark:text-gray-400 py-8">
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
    # TODO: Integrate with v2 HealthManager when UI is updated
    docling_health = nil

    {:ok,
     socket
     |> assign(invitations: invitations, docling_health: docling_health, form: to_form(%{}))}
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

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, invitation_error_message(changeset))}
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

  defp docling_status_label(%{status: "healthy"}), do: "Healthy"
  defp docling_status_label(%{status: "unreachable"}), do: "Unreachable"
  defp docling_status_label(nil), do: "Unknown"
  defp docling_status_label(%{status: status}), do: String.capitalize(status)

  defp docling_status_badge_class(%{status: "healthy"}) do
    "inline-flex items-center rounded-full bg-green-100 px-3 py-1 text-xs font-semibold text-green-800"
  end

  defp docling_status_badge_class(%{status: "unreachable"}) do
    "inline-flex items-center rounded-full bg-red-100 px-3 py-1 text-xs font-semibold text-red-800"
  end

  defp docling_status_badge_class(_),
    do:
      "inline-flex items-center rounded-full bg-gray-100 px-3 py-1 text-xs font-semibold text-gray-800"

  defp docling_status_message(%{status: "healthy", details: details}) do
    "Responding with #{details_description(details)}"
  end

  defp docling_status_message(%{status: "unreachable", details: details}) do
    Map.get(details || %{}, "error", "Service unreachable")
  end

  defp docling_status_message(_), do: "No health checks recorded yet."

  defp docling_check_timestamp(%{responded_at: timestamp}, locale, timezone)
       when not is_nil(timestamp) do
    format_datetime(timestamp, locale: locale, timezone: timezone, format: :medium) ||
      Calendar.strftime(timestamp, "%b %d, %Y %H:%M UTC")
  end

  defp docling_check_timestamp(%{inserted_at: timestamp}, locale, timezone)
       when not is_nil(timestamp) do
    format_datetime(timestamp, locale: locale, timezone: timezone, format: :medium) ||
      Calendar.strftime(timestamp, "%b %d, %Y %H:%M UTC")
  end

  defp docling_check_timestamp(_, _locale, _timezone), do: "Never"

  defp details_description(%{} = details) when map_size(details) > 0 do
    inspect(details)
  end

  defp details_description(_), do: "no additional metadata"

  defp invitation_error_message(%Ecto.Changeset{} = changeset) do
    errors = changeset.errors

    if errors == [] do
      "Failed to create invitation"
    else
      errors
      |> Enum.map(fn {field, error} ->
        label = field |> Phoenix.Naming.humanize() |> String.capitalize()
        message = CoreComponents.translate_error(error)
        label <> " " <> message
      end)
      |> Enum.join(". ")
    end
  end
end
