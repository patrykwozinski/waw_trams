defmodule Mix.Tasks.WawTrams.Cleanup do
  @moduledoc """
  Safely cleans up old delay events data.

  **SAFE BY DEFAULT**: This task only shows what would be deleted.
  You must pass `--execute` to actually delete anything.

  ## Usage

      # Preview what would be deleted (DRY RUN - no changes)
      mix waw_trams.cleanup

      # Actually delete (requires explicit flag)
      mix waw_trams.cleanup --execute

      # Delete events older than N days (default: raw_retention_days config)
      mix waw_trams.cleanup --older-than 14 --execute

      # Skip aggregation check (DANGEROUS - may lose unaggregated data)
      mix waw_trams.cleanup --skip-aggregation-check --execute

  ## Safety Features

  1. **Dry-run by default** - Always shows preview first
  2. **Aggregation check** - Won't delete days that haven't been aggregated
  3. **Retention config** - Uses `raw_retention_days` from config (default: 7)
  4. **Detailed preview** - Shows exactly what will be deleted

  ## Recommended Workflow

      # 1. Run aggregation first
      mix waw_trams.aggregate_daily --backfill 7

      # 2. Preview cleanup
      mix waw_trams.cleanup

      # 3. Execute if preview looks correct
      mix waw_trams.cleanup --execute
  """

  use Mix.Task

  import Ecto.Query
  alias WawTrams.{Repo, DelayEvent, DailyLineStat}

  @shortdoc "Safely cleans up old delay events (dry-run by default)"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} =
      OptionParser.parse(args,
        switches: [
          execute: :boolean,
          older_than: :integer,
          skip_aggregation_check: :boolean,
          resolved_only: :boolean
        ],
        aliases: [e: :execute, o: :older_than, s: :skip_aggregation_check, r: :resolved_only]
      )

    execute? = opts[:execute] || false
    skip_check? = opts[:skip_aggregation_check] || false
    resolved_only? = opts[:resolved_only] || false

    # Get retention days from config or option
    retention_days =
      opts[:older_than] || Application.get_env(:waw_trams, :raw_retention_days, 7)

    cutoff_date = Date.add(Date.utc_today(), -retention_days)
    cutoff_dt = DateTime.new!(cutoff_date, ~T[00:00:00], "Etc/UTC")

    Mix.shell().info("""

    ╔══════════════════════════════════════════════════════════════╗
    ║                    DELAY EVENTS CLEANUP                      ║
    ╚══════════════════════════════════════════════════════════════╝

    Configuration:
      • Retention period: #{retention_days} days
      • Cutoff date: #{cutoff_date} (delete events before this)
      • Mode: #{if execute?, do: "⚠️  EXECUTE (will delete)", else: "🔍 DRY RUN (preview only)"}
      • Aggregation check: #{if skip_check?, do: "⚠️  SKIPPED", else: "✓ Enabled"}
      • Filter: #{if resolved_only?, do: "Resolved only", else: "All events"}
    """)

    # Get counts by date
    date_breakdown = get_date_breakdown(cutoff_dt, resolved_only?)
    total_count = Enum.reduce(date_breakdown, 0, fn {_date, count}, acc -> acc + count end)

    if total_count == 0 do
      Mix.shell().info("✨ No delay events to clean up. All data is within retention period.\n")
    else
      Mix.shell().info("Found #{total_count} events to delete:\n")

      # Check aggregation status for each date
      {safe_dates, unsafe_dates} =
        if skip_check? do
          {date_breakdown, []}
        else
          check_aggregation_status(date_breakdown)
        end

      # Show breakdown
      display_breakdown(safe_dates, unsafe_dates, skip_check?)

      # Calculate what can be safely deleted
      safe_count = Enum.reduce(safe_dates, 0, fn {_date, count}, acc -> acc + count end)
      unsafe_count = Enum.reduce(unsafe_dates, 0, fn {_date, count}, acc -> acc + count end)

      if unsafe_count > 0 and not skip_check? do
        Mix.shell().info("""

        ⚠️  WARNING: #{unsafe_count} events on #{length(unsafe_dates)} day(s) have NOT been aggregated!

        Run aggregation first:
          mix waw_trams.aggregate_daily --backfill #{retention_days + 1}

        Or use --skip-aggregation-check to delete anyway (DATA LOSS!)
        """)
      end

      if safe_count > 0 do
        if execute? do
          # Build query for safe dates only
          safe_dates_list = Enum.map(safe_dates, fn {date, _} -> date end)
          safe_query = build_safe_query(safe_dates_list, resolved_only?)

          Mix.shell().info("\n🗑️  Deleting #{safe_count} events...")
          {deleted, _} = Repo.delete_all(safe_query)
          Mix.shell().info("✓ Deleted #{deleted} delay events.\n")

          if unsafe_count > 0 do
            Mix.shell().info(
              "ℹ️  Skipped #{unsafe_count} unaggregated events. Run aggregation first.\n"
            )
          end
        else
          Mix.shell().info("""

          This was a DRY RUN. No data was deleted.

          To execute deletion, run:
            mix waw_trams.cleanup --execute
          """)
        end
      else
        Mix.shell().info("\n❌ Cannot delete: all events are on unaggregated dates.\n")
      end
    end
  end

  defp build_safe_query(safe_dates, resolved_only?) do
    # Build a query that only deletes events on specific dates
    query =
      from(d in DelayEvent,
        where: fragment("DATE(?)", d.started_at) in ^safe_dates
      )

    if resolved_only? do
      where(query, [d], not is_nil(d.resolved_at))
    else
      query
    end
  end

  defp get_date_breakdown(cutoff_dt, resolved_only?) do
    query =
      from(d in DelayEvent,
        where: d.started_at < ^cutoff_dt,
        group_by: fragment("DATE(?)", d.started_at),
        select: {fragment("DATE(?)", d.started_at), count(d.id)},
        order_by: [asc: fragment("DATE(?)", d.started_at)]
      )

    query =
      if resolved_only? do
        where(query, [d], not is_nil(d.resolved_at))
      else
        query
      end

    Repo.all(query)
  end

  defp check_aggregation_status(date_breakdown) do
    # Get dates that have been aggregated
    aggregated_dates =
      from(s in DailyLineStat,
        distinct: s.date,
        select: s.date
      )
      |> Repo.all()
      |> MapSet.new()

    Enum.split_with(date_breakdown, fn {date, _count} ->
      MapSet.member?(aggregated_dates, date)
    end)
  end

  defp display_breakdown(safe_dates, unsafe_dates, skip_check?) do
    if safe_dates != [] do
      Mix.shell().info("  📦 Aggregated (safe to delete):")

      for {date, count} <- safe_dates do
        Mix.shell().info("     #{date}: #{count} events ✓")
      end
    end

    if unsafe_dates != [] and not skip_check? do
      Mix.shell().info("\n  ⚠️  NOT aggregated (would lose data):")

      for {date, count} <- unsafe_dates do
        Mix.shell().info("     #{date}: #{count} events ✗")
      end
    end
  end
end
