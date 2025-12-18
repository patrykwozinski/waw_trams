defmodule Mix.Tasks.WawTrams.Cleanup do
  @moduledoc """
  Cleans up delay events data.

  ## Usage

      # Delete all delay events
      mix waw_trams.cleanup

      # Delete only resolved delays
      mix waw_trams.cleanup --resolved

      # Delete delays older than N days
      mix waw_trams.cleanup --older-than 7
  """

  use Mix.Task

  @shortdoc "Cleans up delay events data"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} =
      OptionParser.parse(args,
        switches: [resolved: :boolean, older_than: :integer],
        aliases: [r: :resolved, o: :older_than]
      )

    import Ecto.Query
    alias WawTrams.{Repo, DelayEvent}

    query = build_query(opts)

    # Show what will be deleted
    count = Repo.aggregate(query, :count)

    if count == 0 do
      Mix.shell().info("No delay events to delete.")
    else
      Mix.shell().info("Found #{count} delay events to delete.")

      if Mix.shell().yes?("Proceed with deletion?") do
        {deleted, _} = Repo.delete_all(query)
        Mix.shell().info("✓ Deleted #{deleted} delay events.")
      else
        Mix.shell().info("Aborted.")
      end
    end
  end

  defp build_query(opts) do
    import Ecto.Query
    alias WawTrams.DelayEvent

    query = DelayEvent

    query =
      if opts[:resolved] do
        where(query, [d], not is_nil(d.resolved_at))
      else
        query
      end

    query =
      if days = opts[:older_than] do
        cutoff = DateTime.add(DateTime.utc_now(), -days, :day)
        where(query, [d], d.started_at < ^cutoff)
      else
        query
      end

    query
  end
end
