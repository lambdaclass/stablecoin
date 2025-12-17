defmodule StablecoinOpsWeb.Router do
  use StablecoinOpsWeb, :router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {StablecoinOpsWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  pipeline :api do
    plug(:accepts, ["json"])
  end

  scope "/", StablecoinOpsWeb do
    pipe_through(:browser)

    get("/", PageController, :home)

    # networks
    live("/networks", NetworkLive.Index, :index)
    live("/networks/new", NetworkLive.Form, :new)
    live("/networks/:id", NetworkLive.Show, :show)
    live("/networks/:id/edit", NetworkLive.Form, :edit)

    # stablecoins
    live("/stablecoins", StablecoinLive.Index, :index)
    live("/stablecoins/new", StablecoinLive.Form, :new)
    live("/stablecoins/:id", StablecoinLive.Show, :show)
    live("/stablecoins/:id/edit", StablecoinLive.Form, :edit)
  end

  # Other scopes may use custom stacks.
  # scope "/api", StablecoinOpsWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:stablecoin_ops, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through(:browser)

      live_dashboard("/dashboard", metrics: StablecoinOpsWeb.Telemetry)
      forward("/mailbox", Plug.Swoosh.MailboxPreview)
    end
  end
end
