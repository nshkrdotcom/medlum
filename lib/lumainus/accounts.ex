defmodule Lumainus.Accounts do
  @moduledoc """
  The Accounts context.
  """

  import Ecto.Query, warn: false
  alias Lumainus.Repo

  alias Lumainus.Accounts.{User, UserToken, UserNotifier, Invitation}
  alias Lumainus.Docling.Settings
  alias Lumainus.Tenancy.Tenant

  ## Database getters

  @doc """
  Gets a user by email.

  ## Examples

      iex> get_user_by_email("foo@example.com")
      %User{}

      iex> get_user_by_email("unknown@example.com")
      nil

  """
  def get_user_by_email(email) when is_binary(email) do
    Repo.get_by(User, email: email)
  end

  @doc """
  Gets a user by email and password.

  ## Examples

      iex> get_user_by_email_and_password("foo@example.com", "correct_password")
      %User{}

      iex> get_user_by_email_and_password("foo@example.com", "invalid_password")
      nil

  """
  def get_user_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    user = Repo.get_by(User, email: email)
    if User.valid_password?(user, password), do: user
  end

  @doc """
  Gets a single user.

  Raises `Ecto.NoResultsError` if the User does not exist.

  ## Examples

      iex> get_user!(123)
      %User{}

      iex> get_user!(456)
      ** (Ecto.NoResultsError)

  """
  def get_user!(id), do: Repo.get!(User, id)

  ## User registration

  @doc """
  Registers a user.

  ## Examples

      iex> register_user(%{field: value})
      {:ok, %User{}}

      iex> register_user(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def register_user(attrs) do
    attrs = ensure_tenant_id(attrs)

    %User{}
    |> User.registration_changeset(attrs)
    |> Repo.insert()
  end

  ## Invitations

  @doc """
  Creates a new invitation for a user with the specified role.

  ## Examples

      iex> create_invitation(%{role: "doctor", created_by_id: 1})
      {:ok, %Invitation{}}

      iex> create_invitation(%{role: "invalid"})
      {:error, %Ecto.Changeset{}}

  """
  def create_invitation(attrs, created_by_user) do
    token = Invitation.generate_token()

    tenant_id =
      attrs[:tenant_id] ||
        attrs["tenant_id"] ||
        created_by_user.tenant_id ||
        ensure_tenant_id(%{})[:tenant_id]

    %Invitation{}
    |> Invitation.changeset(
      Map.merge(attrs, %{
        token: token,
        created_by_id: created_by_user.id,
        tenant_id: tenant_id
      })
    )
    |> Repo.insert()
  end

  @doc """
  Gets an invitation by its token.

  Returns nil if the invitation does not exist.

  ## Examples

      iex> get_invitation_by_token("valid_token")
      %Invitation{}

      iex> get_invitation_by_token("invalid_token")
      nil

  """
  def get_invitation_by_token(token) when is_binary(token) do
    Repo.get_by(Invitation, token: token)
  end

  @doc """
  Marks an invitation as used and registers the user with the assigned role.

  ## Examples

      iex> use_invitation(invitation, %{email: "user@example.com", password: "password"})
      {:ok, %User{}}

  """
  def use_invitation(%Invitation{} = invitation, user_attrs) do
    if Invitation.valid?(invitation) do
      Repo.transact(fn ->
        string_attrs =
          Map.new(user_attrs, fn
            {key, value} when is_atom(key) -> {Atom.to_string(key), value}
            {key, value} -> {key, value}
          end)

        # Register the user with the role from the invitation
        attrs =
          Map.merge(string_attrs, %{
            "role" => invitation.role,
            "email" => invitation.email || string_attrs["email"],
            "tenant_id" => invitation.tenant_id
          })

        with {:ok, user} <- register_user(attrs),
             {:ok, _invitation} <- Repo.update(Invitation.mark_as_used(invitation)) do
          {:ok, user}
        else
          {:error, changeset} -> {:error, changeset}
        end
      end)
    else
      {:error, :invitation_already_used}
    end
  end

  @doc """
  Lists all invitations, optionally filtered by used/unused status.

  ## Examples

      iex> list_invitations()
      [%Invitation{}, ...]

      iex> list_invitations(only_unused: true)
      [%Invitation{}, ...]

  """
  def list_invitations(opts \\ []) do
    query = from(i in Invitation, order_by: [desc: i.inserted_at])

    query =
      if opts[:only_unused] do
        from(i in query, where: is_nil(i.used_at))
      else
        query
      end

    query =
      if opts[:created_by_id] do
        from(i in query, where: i.created_by_id == ^opts[:created_by_id])
      else
        query
      end

    Repo.all(query) |> Repo.preload(:created_by)
  end

  defp ensure_tenant_id(attrs) do
    existing =
      Map.get(attrs, :tenant_id) ||
        Map.get(attrs, "tenant_id")

    if existing do
      attrs
    else
      tenant_id = default_tenant_id()

      case key_type(attrs) do
        :string -> Map.put(attrs, "tenant_id", tenant_id)
        _ -> Map.put(attrs, :tenant_id, tenant_id)
      end
    end
  end

  defp default_tenant_id do
    Tenant
    |> select([t], t.id)
    |> limit(1)
    |> Repo.one() ||
      raise "No tenants present; run tenant migrations"
  end

  defp key_type(map) do
    keys = Map.keys(map)

    cond do
      Enum.all?(keys, &is_binary/1) -> :string
      Enum.all?(keys, &is_atom/1) -> :atom
      true -> :atom
    end
  end

  @doc """
  Deletes an invitation.

  ## Examples

      iex> delete_invitation(invitation)
      {:ok, %Invitation{}}

  """
  def delete_invitation(%Invitation{} = invitation) do
    Repo.delete(invitation)
  end

  ## Settings

  @doc """
  Returns the user's preferred Docling backend, falling back to the configured default.
  """
  def docling_backend_for_user(%User{} = user, opts \\ []) do
    default = user_backend_default()

    user.docling_backend
    |> Kernel.||(default |> Atom.to_string())
    |> normalize_user_backend()
    |> apply_backend_override(opts)
  end

  defp apply_backend_override(current, opts) do
    override = Keyword.get(opts, :backend)

    case override do
      nil -> current
      backend -> normalize_user_backend(backend)
    end
  end

  @doc """
  Persist a user's Docling backend preference (`:local` | `:fast`).
  """
  def update_docling_backend(%User{} = user, backend) do
    backend_atom = normalize_user_backend(backend)
    backend_string = Atom.to_string(backend_atom)

    user
    |> User.docling_backend_changeset(%{docling_backend: backend_string})
    |> Repo.update()
  end

  # User backend preference helpers
  defp user_backend_default do
    {:ok, settings} = Settings.fetch_or_init()

    case settings.default_mode do
      "cloud" -> :cloud
      _ -> :local
    end
  end

  defp normalize_user_backend(nil), do: :local
  defp normalize_user_backend(:local), do: :local
  defp normalize_user_backend("local"), do: :local
  defp normalize_user_backend(:cloud), do: :cloud
  defp normalize_user_backend("cloud"), do: :cloud
  defp normalize_user_backend(:fast), do: :cloud
  defp normalize_user_backend("fast"), do: :cloud
  defp normalize_user_backend(_), do: :local

  @doc """
  Checks whether the user is in sudo mode.

  The user is in sudo mode when the last authentication was done no further
  than 20 minutes ago. The limit can be given as second argument in minutes.
  """
  def sudo_mode?(user, minutes \\ -20)

  def sudo_mode?(%User{authenticated_at: ts}, minutes) when is_struct(ts, DateTime) do
    DateTime.after?(ts, DateTime.utc_now() |> DateTime.add(minutes, :minute))
  end

  def sudo_mode?(_user, _minutes), do: false

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user email.

  See `Lumainus.Accounts.User.email_changeset/3` for a list of supported options.

  ## Examples

      iex> change_user_email(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_email(user, attrs \\ %{}, opts \\ []) do
    User.email_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user email using the given token.

  If the token matches, the user email is updated and the token is deleted.
  """
  def update_user_email(user, token) do
    context = "change:#{user.email}"

    Repo.transact(fn ->
      with {:ok, query} <- UserToken.verify_change_email_token_query(token, context),
           %UserToken{sent_to: email} <- Repo.one(query),
           {:ok, user} <- Repo.update(User.email_changeset(user, %{email: email})),
           {_count, _result} <-
             Repo.delete_all(from(UserToken, where: [user_id: ^user.id, context: ^context])) do
        {:ok, user}
      else
        _ -> {:error, :transaction_aborted}
      end
    end)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user password.

  See `Lumainus.Accounts.User.password_changeset/3` for a list of supported options.

  ## Examples

      iex> change_user_password(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_password(user, attrs \\ %{}, opts \\ []) do
    User.password_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user password.

  Returns a tuple with the updated user, as well as a list of expired tokens.

  ## Examples

      iex> update_user_password(user, %{password: ...})
      {:ok, {%User{}, [...]}}

      iex> update_user_password(user, %{password: "too short"})
      {:error, %Ecto.Changeset{}}

  """
  def update_user_password(user, attrs) do
    user
    |> User.password_changeset(attrs)
    |> update_user_and_delete_all_tokens()
  end

  ## Session

  @doc """
  Generates a session token.
  """
  def generate_user_session_token(user) do
    {token, user_token} = UserToken.build_session_token(user)
    Repo.insert!(user_token)
    token
  end

  @doc """
  Gets the user with the given signed token.

  If the token is valid `{user, token_inserted_at}` is returned, otherwise `nil` is returned.
  """
  def get_user_by_session_token(token) do
    {:ok, query} = UserToken.verify_session_token_query(token)
    Repo.one(query)
  end

  @doc """
  Gets the user with the given magic link token.
  """
  def get_user_by_magic_link_token(token) do
    with {:ok, query} <- UserToken.verify_magic_link_token_query(token),
         {user, _token} <- Repo.one(query) do
      user
    else
      _ -> nil
    end
  end

  @doc """
  Logs the user in by magic link.

  There are three cases to consider:

  1. The user has already confirmed their email. They are logged in
     and the magic link is expired.

  2. The user has not confirmed their email and no password is set.
     In this case, the user gets confirmed, logged in, and all tokens -
     including session ones - are expired. In theory, no other tokens
     exist but we delete all of them for best security practices.

  3. The user has not confirmed their email but a password is set.
     This cannot happen in the default implementation but may be the
     source of security pitfalls. See the "Mixing magic link and password registration" section of
     `mix help phx.gen.auth`.
  """
  def login_user_by_magic_link(token) do
    {:ok, query} = UserToken.verify_magic_link_token_query(token)

    case Repo.one(query) do
      # Unconfirmed user (with or without password) - confirm and log in.
      # Note: The default Phoenix auth generator raises an error for unconfirmed users
      # with passwords to prevent session fixation attacks. However, our invitation-based
      # registration flow is not vulnerable since the same user who registers (and sets
      # their password) is the one who clicks the confirmation link.
      {%User{confirmed_at: nil} = user, _token} ->
        user
        |> User.confirm_changeset()
        |> update_user_and_delete_all_tokens()

      {user, token} ->
        Repo.delete!(token)
        {:ok, {user, []}}

      nil ->
        {:error, :not_found}
    end
  end

  @doc ~S"""
  Delivers the update email instructions to the given user.

  ## Examples

      iex> deliver_user_update_email_instructions(user, current_email, &url(~p"/users/settings/confirm-email/#{&1}"))
      {:ok, %{to: ..., body: ...}}

  """
  def deliver_user_update_email_instructions(%User{} = user, current_email, update_email_url_fun)
      when is_function(update_email_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "change:#{current_email}")

    Repo.insert!(user_token)
    UserNotifier.deliver_update_email_instructions(user, update_email_url_fun.(encoded_token))
  end

  @doc """
  Delivers the magic link login instructions to the given user.
  """
  def deliver_login_instructions(%User{} = user, magic_link_url_fun)
      when is_function(magic_link_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "login")
    Repo.insert!(user_token)
    UserNotifier.deliver_login_instructions(user, magic_link_url_fun.(encoded_token))
  end

  @doc """
  Deletes the signed token with the given context.
  """
  def delete_user_session_token(token) do
    Repo.delete_all(from(UserToken, where: [token: ^token, context: "session"]))
    :ok
  end

  ## Token helper

  defp update_user_and_delete_all_tokens(changeset) do
    Repo.transact(fn ->
      with {:ok, user} <- Repo.update(changeset) do
        tokens_to_expire = Repo.all_by(UserToken, user_id: user.id)

        Repo.delete_all(from(t in UserToken, where: t.id in ^Enum.map(tokens_to_expire, & &1.id)))

        {:ok, {user, tokens_to_expire}}
      end
    end)
  end
end
