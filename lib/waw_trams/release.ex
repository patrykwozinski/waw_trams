defmodule WawTrams.Release do
  @moduledoc """
  Release tasks for production deployments.

  Used by Fly.io's release_command to run migrations before starting the app.

  ## Usage

      # Run migrations (automatic on deploy)
      /app/bin/waw_trams eval "WawTrams.Release.migrate"

      # Seed initial data (run once after first deploy)
      /app/bin/waw_trams eval "WawTrams.Release.seed"
  """

  @app :waw_trams

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  @doc """
  Seeds initial data (stops, intersections, line_terminals).
  Idempotent - skips if data already exists.

  Run once after first deploy:
      fly ssh console -C "/app/bin/waw_trams eval 'WawTrams.Release.seed'"
  """
  def seed do
    load_app()
    {:ok, _} = Application.ensure_all_started(@app)

    WawTrams.Seeder.seed_all()
    WawTrams.Seeder.mark_terminal_stops()
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
