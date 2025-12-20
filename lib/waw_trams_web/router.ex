defmodule WawTramsWeb.Router do
  use WawTramsWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {WawTramsWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug WawTramsWeb.Plugs.Locale
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", WawTramsWeb do
    pipe_through :browser

    live_session :default, on_mount: WawTramsWeb.LocaleHook do
      live "/", AuditLive
      live "/dashboard", DashboardLive
      live "/line", LineLive
      live "/line/:line", LineLive
    end
  end

  # Other scopes may use custom stacks.
  # scope "/api", WawTramsWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:waw_trams, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: WawTramsWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview

      # Test endpoints to simulate delays
      get "/pulse", WawTramsWeb.DevController, :pulse
      get "/delay/start", WawTramsWeb.DevController, :delay_start
      get "/delay/end", WawTramsWeb.DevController, :delay_end
    end
  end
end
