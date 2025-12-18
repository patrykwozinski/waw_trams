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

      # NUCLEAR OPTION: Delete ALL data and start fresh
      mix waw_trams.cleanup --reset-all --execute --i-know-what-i-am-doing

  ## Safety Features

  1. **Dry-run by default** - Always shows preview first
  2. **Aggregation check** - Won't delete days that haven't been aggregated
  3. **Retention config** - Uses `raw_retention_days` from config (default: 7)
  4. **Detailed preview** - Shows exactly what will be deleted
  5. **Production safety** - `--reset-all` requires explicit confirmation flag

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
  alias WawTrams.{Repo, DelayEvent, DailyLineStat, DailyIntersectionStat, HourlyPattern}

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
          resolved_only: :boolean,
          reset_all: :boolean,
          i_know_what_i_am_doing: :boolean
        ],
        aliases: [e: :execute, o: :older_than, s: :skip_aggregation_check, r: :resolved_only]
      )

    if opts[:reset_all] do
      run_reset_all(opts)
    else
      run_retention_cleanup(opts)
    end
  end

  # ============================================================
  # RESET ALL - Nuclear option to start fresh
  # ============================================================

  defp run_reset_all(opts) do
    execute? = opts[:execute] || false
    confirmed? = opts[:i_know_what_i_am_doing] || false

    # Check environment
    env = Mix.env()
    is_prod? = env == :prod

    # Get current counts
    delay_count = Repo.one(from d in DelayEvent, select: count(d.id))
    line_stat_count = Repo.one(from s in DailyLineStat, select: count(s.id))
    intersection_stat_count = Repo.one(from s in DailyIntersectionStat, select: count(s.id))
    pattern_count = Repo.one(from p in HourlyPattern, select: count(p.id))

    total = delay_count + line_stat_count + intersection_stat_count + pattern_count

    Mix.shell().info("""

    ╔══════════════════════════════════════════════════════════════╗
    ║              ⚠️  RESET ALL DATA - NUCLEAR OPTION  ⚠️          ║
    ╚══════════════════════════════════════════════════════════════╝

    Environment: #{env}#{if is_prod?, do: " ⚠️  PRODUCTION!", else: ""}

    This will DELETE ALL:
      • delay_events:           #{delay_count} records
      • daily_line_stats:       #{line_stat_count} records
      • daily_intersection_stats: #{intersection_stat_count} records
      • hourly_patterns:        #{pattern_count} records
      ────────────────────────────
      TOTAL:                    #{total} records

    """)

    cond do
      total == 0 ->
        Mix.shell().info("✨ Database is already empty. Nothing to delete.\n")

      not execute? ->
        Mix.shell().info("""
        This was a DRY RUN. No data was deleted.

        To execute, run:
          mix waw_trams.cleanup --reset-all --execute --i-know-what-i-am-doing
        """)

      is_prod? and not confirmed? ->
        Mix.shell().error("""
        ❌ BLOCKED: Production environment detected!

        To reset production data, you MUST add the confirmation flag:
          mix waw_trams.cleanup --reset-all --execute --i-know-what-i-am-doing

        This is a safety measure to prevent accidental data loss.
        """)

        exit({:shutdown, 1})

      not confirmed? ->
        Mix.shell().info("""
        ⚠️  Missing confirmation flag.

        To delete all data, run:
          mix waw_trams.cleanup --reset-all --execute --i-know-what-i-am-doing
        """)

      true ->
        Mix.shell().info("🗑️  Deleting all data...")

        {d1, _} = Repo.delete_all(DelayEvent)
        {d2, _} = Repo.delete_all(DailyLineStat)
        {d3, _} = Repo.delete_all(DailyIntersectionStat)
        {d4, _} = Repo.delete_all(HourlyPattern)

        Mix.shell().info("""

        ✅ Reset complete!
          • delay_events:           #{d1} deleted
          • daily_line_stats:       #{d2} deleted
          • daily_intersection_stats: #{d3} deleted
          • hourly_patterns:        #{d4} deleted

        Database is now empty. Start fresh with:
          mix phx.server
        """)
    end
  end

  # ============================================================
  # RETENTION-BASED CLEANUP - Original behavior
  # ============================================================

  defp run_retention_cleanup(opts) do
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
