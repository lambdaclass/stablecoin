defmodule StablecoinOps.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      StablecoinOpsWeb.Telemetry,
      StablecoinOps.Repo,
      {DNSCluster, query: Application.get_env(:stablecoin_ops, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: StablecoinOps.PubSub},
      # Start a worker by calling: StablecoinOps.Worker.start_link(arg)
      # {StablecoinOps.Worker, arg},
      # Start to serve requests, typically the last entry
      StablecoinOpsWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: StablecoinOps.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    StablecoinOpsWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
