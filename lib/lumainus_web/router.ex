defmodule LumainusWeb.Router do
  use LumainusWeb, :router

  # Import authentication plugs
  import LumainusWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {LumainusWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api", LumainusWeb do
    pipe_through :api

    post "/uploads", Api.UploadController, :create
    get "/uploads/:id/status", Api.UploadController, :status
    get "/uploads/:id/download", Api.UploadController, :download_markdown
    get "/jobs/:id/status", Api.JobController, :status
    get "/jobs/:id/stream", Api.JobController, :stream
  end

  # Public routes - anyone can access
  scope "/", LumainusWeb do
    pipe_through :browser
    get "/", PageController, :home
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:lumainus, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: LumainusWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  ## Authentication routes - public login/register
  scope "/", LumainusWeb do
    pipe_through [:browser]

    live_session :current_user,
      on_mount: [{LumainusWeb.UserAuth, :mount_current_scope}] do
      live "/users/register", UserLive.Registration, :new
      live "/users/register/:token", UserLive.Registration, :new
      live "/users/log-in", UserLive.Login, :new
      live "/users/log-in/:token", UserLive.Confirmation, :new
    end

    post "/users/register/:token", UserRegistrationController, :create
    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end

  ## User settings - any authenticated user
  scope "/", LumainusWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_authenticated_user,
      on_mount: [{LumainusWeb.UserAuth, :require_authenticated}] do
      live "/users/settings", UserLive.Settings, :edit
      live "/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email
    end

    post "/users/update-password", UserSessionController, :update_password
  end

  ## Doctor routes - require doctor role or higher
  scope "/", LumainusWeb do
    pipe_through [:browser, :require_authenticated_user, :require_doctor_role]

    live_session :doctor_routes,
      on_mount: [{LumainusWeb.UserAuth, :ensure_authenticated}] do
      live "/reports", ReportsLive
      live "/prompts", PromptsLive
    end
  end

  ## Admin routes - require admin role or higher
  scope "/admin", LumainusWeb do
    pipe_through [:browser, :require_authenticated_user, :require_admin_role]

    live_session :admin_routes,
      on_mount: [{LumainusWeb.UserAuth, :ensure_authenticated}] do
      live "/invitations", Admin.InvitationsLive
    end
  end
end
