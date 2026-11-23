defmodule MedlumWeb.Router do
  use MedlumWeb, :router

  # Import authentication plugs
  import MedlumWeb.UserAuth

  # Import Backpex routes macro
  import Backpex.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {MedlumWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
    plug MedlumWeb.Locale
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api", MedlumWeb do
    pipe_through :api

    post "/uploads", Api.UploadController, :create
    get "/uploads/:id/status", Api.UploadController, :status
    get "/uploads/:id/download", Api.UploadController, :download_markdown
    get "/jobs/:id/status", Api.JobController, :status
    get "/jobs/:id/stream", Api.JobController, :stream
  end

  # Public routes - anyone can access
  scope "/", MedlumWeb do
    pipe_through :browser
    get "/", PageController, :home
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:medlum, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: MedlumWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  ## Authentication routes - public login/register
  scope "/", MedlumWeb do
    pipe_through [:browser]

    live_session :current_user,
      on_mount: [{MedlumWeb.UserAuth, :mount_current_scope}, {MedlumWeb.Locale, :set_locale}] do
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
  scope "/", MedlumWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_authenticated_user,
      on_mount: [
        {MedlumWeb.UserAuth, :require_authenticated},
        {MedlumWeb.Locale, :set_locale}
      ] do
      live "/users/settings", UserLive.Settings, :edit
      live "/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email
    end

    post "/users/update-password", UserSessionController, :update_password
  end

  ## Doctor routes - require doctor role or higher
  scope "/", MedlumWeb do
    pipe_through [:browser, :require_authenticated_user, :require_doctor_role]

    live_session :doctor_routes,
      on_mount: [{MedlumWeb.UserAuth, :ensure_authenticated}, {MedlumWeb.Locale, :set_locale}] do
      live "/reports", ReportsLive
    end
  end

  ## Admin routes - require admin role or higher
  scope "/admin", MedlumWeb do
    pipe_through [:browser, :require_authenticated_user, :require_admin_role]

    live_session :admin_routes,
      on_mount: [{MedlumWeb.UserAuth, :ensure_authenticated}, {MedlumWeb.Locale, :set_locale}] do
      live "/invitations", Admin.InvitationsLive
      live "/docling", Admin.DoclingSettingsLive
      live "/vast_ai", Admin.VastAILive
      live "/gpu_events", Admin.GPUEventsLive
      # LLM Config Studio - comprehensive LLM configuration
      live "/llm-config", Admin.LlmConfigLive
    end
  end

  ## Admin Database Browser (Backpex) - require admin role
  scope "/admin/db", MedlumWeb do
    pipe_through [:browser, :require_authenticated_user, :require_admin_role]

    # Backpex cookie routes
    backpex_routes()

    live_session :admin_db,
      on_mount: [
        Backpex.InitAssigns,
        {MedlumWeb.UserAuth, :ensure_authenticated},
        {MedlumWeb.Locale, :set_locale}
      ],
      root_layout: {MedlumWeb.Layouts, :root} do
      live_resources("/users", Admin.Db.UserLive)
      live_resources("/tenants", Admin.Db.TenantLive)
      live_resources("/patients", Admin.Db.PatientLive)
      live_resources("/report_runs", Admin.Db.ReportRunLive)
      live_resources("/report_section_runs", Admin.Db.ReportSectionRunLive)
      live_resources("/report_templates", Admin.Db.ReportTemplateLive)
      live_resources("/report_section_templates", Admin.Db.ReportSectionTemplateLive)
      live_resources("/llm_invocations", Admin.Db.LlmInvocationLive)
      live_resources("/document_uploads", Admin.Db.DocumentUploadLive)
      live_resources("/ingestion_jobs", Admin.Db.IngestionJobLive)
    end
  end
end
