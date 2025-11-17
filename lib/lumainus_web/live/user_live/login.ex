defmodule LumainusWeb.UserLive.Login do
  use LumainusWeb, :live_view

  alias Lumainus.Accounts
  alias LumainusWeb.Layouts

  @impl true
  def render(assigns) do
    ~H"""
    <style>
      /* Hide the root layout menu on login page */
      body > ul.menu {
        display: none !important;
      }

      /* Make body full height and remove default styling */
      body {
        margin: 0;
        padding: 0;
        min-height: 100vh;
      }
    </style>

    <div class="lumainus-login-page">
      <style>
        .lumainus-login-page {
          min-height: 100vh;
          background: linear-gradient(135deg, #0a0f1e 0%, #0f172a 50%, #1e293b 100%);
          position: relative;
          overflow: hidden;
          display: flex;
          align-items: center;
          justify-content: center;
          padding: 2rem;
        }

        /* Animated background patterns */
        .lumainus-login-page::before {
          content: '';
          position: absolute;
          inset: 0;
          background-image: url('/images/patterns/composite-hero-pattern.svg');
          background-size: cover;
          background-position: center;
          opacity: 0.4;
          animation: breathe 8s ease-in-out infinite;
          z-index: 0;
        }

        /* Secondary pattern layer for depth */
        .lumainus-login-page::after {
          content: '';
          position: absolute;
          inset: 0;
          background-image: url('/images/patterns/neural-network-pattern.svg');
          background-size: 400px 400px;
          opacity: 0.2;
          animation: drift 30s linear infinite;
          z-index: 0;
        }

        @keyframes breathe {
          0%, 100% { opacity: 0.3; transform: scale(1); }
          50% { opacity: 0.5; transform: scale(1.02); }
        }

        @keyframes drift {
          from { background-position: 0 0; }
          to { background-position: 400px 400px; }
        }

        /* Login container */
        .login-container {
          position: relative;
          z-index: 10;
          width: 100%;
          max-width: 480px;
          animation: fadeInUp 0.8s ease-out;
        }

        @keyframes fadeInUp {
          from {
            opacity: 0;
            transform: translateY(30px);
          }
          to {
            opacity: 1;
            transform: translateY(0);
          }
        }

        /* Logo container */
        .logo-container {
          text-align: center;
          margin-bottom: 3rem;
          animation: fadeInScale 1s ease-out 0.2s backwards;
        }

        @keyframes fadeInScale {
          from {
            opacity: 0;
            transform: scale(0.9);
          }
          to {
            opacity: 1;
            transform: scale(1);
          }
        }

        .logo-container img {
          width: 120px;
          height: 120px;
          margin: 0 auto 1.5rem;
          filter: drop-shadow(0 0 30px rgba(59, 130, 246, 0.5));
          animation: logoFloat 6s ease-in-out infinite;
        }

        @keyframes logoFloat {
          0%, 100% { transform: translateY(0px); }
          50% { transform: translateY(-10px); }
        }

        .brand-name {
          font-size: 2.5rem;
          font-weight: 700;
          background: linear-gradient(135deg, #60a5fa, #3b82f6, #2563eb);
          -webkit-background-clip: text;
          -webkit-text-fill-color: transparent;
          background-clip: text;
          letter-spacing: -0.02em;
          margin-bottom: 0.5rem;
        }

        .brand-tagline {
          font-size: 0.875rem;
          color: #94a3b8;
          max-width: 400px;
          margin: 0 auto;
          line-height: 1.6;
        }

        .brand-tagline em {
          color: #60a5fa;
          font-style: normal;
          font-weight: 500;
        }

        /* Glass morphism card */
        .login-card {
          background: rgba(15, 23, 42, 0.7);
          backdrop-filter: blur(20px);
          border: 1px solid rgba(59, 130, 246, 0.2);
          border-radius: 1.5rem;
          padding: 3rem 2.5rem;
          box-shadow:
            0 20px 60px rgba(0, 0, 0, 0.4),
            0 0 0 1px rgba(59, 130, 246, 0.1) inset,
            0 0 40px rgba(59, 130, 246, 0.1);
          position: relative;
          overflow: hidden;
        }

        .login-card::before {
          content: '';
          position: absolute;
          top: 0;
          left: 0;
          right: 0;
          height: 2px;
          background: linear-gradient(90deg, transparent, #3b82f6, transparent);
          opacity: 0.6;
        }

        /* Form sections */
        .form-section {
          margin-bottom: 2rem;
        }

        .form-section-title {
          font-size: 1.5rem;
          font-weight: 600;
          color: #f8fafc;
          margin-bottom: 0.5rem;
          text-align: center;
        }

        .form-section-subtitle {
          font-size: 0.875rem;
          color: #94a3b8;
          text-align: center;
          margin-bottom: 2rem;
          line-height: 1.6;
        }

        /* Enhanced inputs */
        .login-card input[type="email"],
        .login-card input[type="password"] {
          background: rgba(15, 23, 42, 0.6);
          border: 1px solid rgba(59, 130, 246, 0.3);
          border-radius: 0.75rem;
          color: #f8fafc;
          padding: 0.875rem 1.25rem;
          width: 100%;
          font-size: 1rem;
          transition: all 0.3s ease;
          margin-bottom: 1rem;
        }

        .login-card input[type="email"]:focus,
        .login-card input[type="password"]:focus {
          outline: none;
          border-color: #3b82f6;
          background: rgba(15, 23, 42, 0.8);
          box-shadow:
            0 0 0 3px rgba(59, 130, 246, 0.1),
            0 0 20px rgba(59, 130, 246, 0.2);
        }

        .login-card input::placeholder {
          color: #64748b;
        }

        /* Enhanced buttons */
        .login-btn {
          width: 100%;
          padding: 1rem 2rem;
          background: linear-gradient(135deg, #3b82f6, #2563eb);
          border: none;
          border-radius: 0.75rem;
          color: white;
          font-weight: 600;
          font-size: 1rem;
          cursor: pointer;
          transition: all 0.3s ease;
          position: relative;
          overflow: hidden;
          box-shadow: 0 4px 20px rgba(59, 130, 246, 0.3);
        }

        .login-btn::before {
          content: '';
          position: absolute;
          top: 0;
          left: -100%;
          width: 100%;
          height: 100%;
          background: linear-gradient(90deg, transparent, rgba(255, 255, 255, 0.2), transparent);
          transition: left 0.5s ease;
        }

        .login-btn:hover {
          transform: translateY(-2px);
          box-shadow: 0 8px 30px rgba(59, 130, 246, 0.4);
        }

        .login-btn:hover::before {
          left: 100%;
        }

        .login-btn:active {
          transform: translateY(0);
        }

        .login-btn-secondary {
          background: rgba(59, 130, 246, 0.1);
          border: 1px solid rgba(59, 130, 246, 0.3);
          box-shadow: none;
        }

        .login-btn-secondary:hover {
          background: rgba(59, 130, 246, 0.15);
          border-color: rgba(59, 130, 246, 0.5);
        }

        /* Divider */
        .form-divider {
          display: flex;
          align-items: center;
          margin: 2rem 0;
          color: #64748b;
          font-size: 0.875rem;
        }

        .form-divider::before,
        .form-divider::after {
          content: '';
          flex: 1;
          height: 1px;
          background: rgba(59, 130, 246, 0.2);
        }

        .form-divider span {
          padding: 0 1rem;
        }

        /* Alert box */
        .dev-alert {
          background: rgba(6, 182, 212, 0.1);
          border: 1px solid rgba(6, 182, 212, 0.3);
          border-radius: 0.75rem;
          padding: 1rem;
          margin-bottom: 1.5rem;
          display: flex;
          gap: 0.75rem;
          align-items: flex-start;
        }

        .dev-alert-icon {
          color: #06b6d4;
          flex-shrink: 0;
        }

        .dev-alert-content {
          color: #cbd5e1;
          font-size: 0.875rem;
          line-height: 1.6;
        }

        .dev-alert-content a {
          color: #06b6d4;
          text-decoration: underline;
          text-underline-offset: 2px;
        }

        .dev-alert-content a:hover {
          color: #22d3ee;
        }

        /* Responsive */
        @media (max-width: 640px) {
          .lumainus-login-page {
            padding: 1rem;
          }

          .login-card {
            padding: 2rem 1.5rem;
          }

          .logo-container img {
            width: 90px;
            height: 90px;
          }

          .brand-name {
            font-size: 2rem;
          }
        }

        /* Flash messages - styled to match login page */
        .lumainus-login-page #flash-group {
          position: fixed;
          top: 2rem;
          right: 2rem;
          z-index: 100;
          max-width: 400px;
        }

        .lumainus-login-page #flash-group > div {
          background: rgba(15, 23, 42, 0.95);
          backdrop-filter: blur(20px);
          border: 1px solid rgba(59, 130, 246, 0.3);
          border-radius: 0.75rem;
          padding: 1rem 1.25rem;
          margin-bottom: 0.75rem;
          box-shadow: 0 10px 40px rgba(0, 0, 0, 0.4);
          animation: slideInRight 0.3s ease-out;
        }

        .lumainus-login-page #flash-group [role="alert"][data-kind="info"] {
          border-color: rgba(6, 182, 212, 0.5);
          background: rgba(6, 182, 212, 0.1);
        }

        .lumainus-login-page #flash-group [role="alert"][data-kind="error"] {
          border-color: rgba(239, 68, 68, 0.5);
          background: rgba(239, 68, 68, 0.1);
        }

        @keyframes slideInRight {
          from {
            opacity: 0;
            transform: translateX(100px);
          }
          to {
            opacity: 1;
            transform: translateX(0);
          }
        }

        /* Accessibility - Respect prefers-reduced-motion */
        @media (prefers-reduced-motion: reduce) {
          .lumainus-login-page::before,
          .lumainus-login-page::after,
          .logo-container img,
          .login-btn::before,
          #flash-group > div {
            animation: none !important;
          }
        }

        /* Flash messages responsive */
        @media (max-width: 640px) {
          .lumainus-login-page #flash-group {
            left: 1rem;
            right: 1rem;
            top: 1rem;
            max-width: none;
          }
        }
      </style>

      <div class="login-container">
        <!-- Logo and branding -->
        <div class="logo-container">
          <img src={~p"/images/lumainus-logo-enhanced.svg"} alt="Lumainus" />
          <h1 class="brand-name">LUMAINUS</h1>
          <p class="brand-tagline">
            Every token has a <em>traceable decision path</em>.<br />
            Every claim has <em>attributable evidence</em>.<br />
            Every response has <em>measurable confidence</em>.
          </p>
        </div>
        
    <!-- Login card -->
        <div class="login-card">
          <div class="form-section">
            <h2 class="form-section-title">Welcome</h2>
            <p class="form-section-subtitle">
              <%= if @current_scope do %>
                Re-authenticate to perform sensitive actions on your account.
              <% else %>
                Enter your credentials to access the platform.
              <% end %>
            </p>
          </div>

          <div :if={local_mail_adapter?()} class="dev-alert">
            <.icon name="hero-information-circle" class="dev-alert-icon size-6" />
            <div class="dev-alert-content">
              <p>Development mode: Local mail adapter active.</p>
              <p>
                View sent emails at <.link href="/dev/mailbox">the mailbox page</.link>.
              </p>
            </div>
          </div>
          
    <!-- Magic link login -->
          <.form
            :let={f}
            for={@form}
            id="login_form_magic"
            action={~p"/users/log-in"}
            phx-submit="submit_magic"
          >
            <.input
              readonly={!!@current_scope}
              field={f[:email]}
              type="email"
              label="Email Address"
              autocomplete="username"
              required
              phx-mounted={JS.focus()}
            />
            <button type="submit" class="login-btn">
              Log in with email <span aria-hidden="true">→</span>
            </button>
          </.form>

          <div class="form-divider">
            <span>or</span>
          </div>
          
    <!-- Password login -->
          <.form
            :let={f}
            for={@form}
            id="login_form_password"
            action={~p"/users/log-in"}
            phx-submit="submit_password"
            phx-trigger-action={@trigger_submit}
          >
            <.input
              readonly={!!@current_scope}
              field={f[:email]}
              type="email"
              label="Email Address"
              autocomplete="username"
              required
            />
            <.input
              field={@form[:password]}
              type="password"
              label="Password"
              autocomplete="current-password"
            />
            <button
              type="submit"
              class="login-btn"
              name={@form[:remember_me].name}
              value="true"
            >
              Log in and stay logged in <span aria-hidden="true">→</span>
            </button>
            <button type="submit" class="login-btn login-btn-secondary" style="margin-top: 0.75rem;">
              Log in only this time
            </button>
          </.form>
        </div>
      </div>

      <Layouts.flash_group flash={@flash} />
    </div>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    email =
      Phoenix.Flash.get(socket.assigns.flash, :email) ||
        get_in(socket.assigns, [:current_scope, Access.key(:user), Access.key(:email)])

    form = to_form(%{"email" => email}, as: "user")

    {:ok,
     assign(socket,
       form: form,
       trigger_submit: false,
       page_icon_href: ~p"/assets/lumainus-icon.svg"
     )}
  end

  @impl true
  def handle_event("submit_password", _params, socket) do
    {:noreply, assign(socket, :trigger_submit, true)}
  end

  def handle_event("submit_magic", %{"user" => %{"email" => email}}, socket) do
    if user = Accounts.get_user_by_email(email) do
      Accounts.deliver_login_instructions(
        user,
        &url(~p"/users/log-in/#{&1}")
      )
    end

    info =
      "If your email is in our system, you will receive instructions for logging in shortly."

    {:noreply,
     socket
     |> put_flash(:info, info)
     |> push_navigate(to: ~p"/users/log-in")}
  end

  defp local_mail_adapter? do
    Application.get_env(:lumainus, Lumainus.Mailer)[:adapter] == Swoosh.Adapters.Local
  end
end
