defmodule WawTrams.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      WawTramsWeb.Telemetry,
      WawTrams.Repo,
      {DNSCluster, query: Application.get_env(:waw_trams, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: WawTrams.PubSub},

      # Tram tracking system
      {Registry, keys: :unique, name: WawTrams.TramRegistry},
      WawTrams.TramSupervisor,
      WawTrams.Poller,

      # Hourly aggregation (runs at minute 5 of each hour)
      WawTrams.HourlyAggregator,

      # Start to serve requests, typically the last entry
      WawTramsWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: WawTrams.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        # Clean up orphaned delays from previous server runs
        WawTrams.DelayEvent.resolve_orphaned()
        {:ok, pid}

      error ->
        error
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    WawTramsWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
