defmodule Mix.Tasks.WawTrams.AggregateDaily do
  @moduledoc """
  Aggregates delay events into daily statistics tables.

  Run nightly (e.g., via cron at 00:05) to aggregate the previous day's data.

  ## Usage

      # Aggregate yesterday (default, for cron)
      mix waw_trams.aggregate_daily

      # Aggregate specific date
      mix waw_trams.aggregate_daily --date 2025-12-17

      # Backfill last N days
      mix waw_trams.aggregate_daily --backfill 7

      # Dry run (show what would be aggregated)
      mix waw_trams.aggregate_daily --dry-run

  ## What it does

  1. Queries delay_events for the target date(s)
  2. Aggregates by location (rounded coords) → daily_intersection_stats
  3. Aggregates by line (with hourly breakdown) → daily_line_stats
  4. Updates cumulative hourly_patterns counters
  """

  use Mix.Task

  alias WawTrams.{Repo, DelayEvent, DailyIntersectionStat, DailyLineStat, HourlyPattern}
  import Ecto.Query

  @shortdoc "Aggregate delay events into daily statistics"

  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} =
      OptionParser.parse(args,
        switches: [date: :string, backfill: :integer, dry_run: :boolean],
        aliases: [d: :date, b: :backfill, n: :dry_run]
      )

    cond do
      opts[:backfill] ->
        backfill(opts[:backfill], opts[:dry_run] || false)

      opts[:date] ->
        case Date.from_iso8601(opts[:date]) do
          {:ok, date} -> aggregate_date(date, opts[:dry_run] || false)
          {:error, _} -> Mix.shell().error("Invalid date format. Use YYYY-MM-DD")
        end

      true ->
        # Default: aggregate yesterday
        yesterday = Date.add(Date.utc_today(), -1)
        aggregate_date(yesterday, opts[:dry_run] || false)
    end
  end

  defp backfill(days, dry_run) do
    Mix.shell().info("Backfilling last #{days} days...")

    dates =
      for i <- days..1 do
        Date.add(Date.utc_today(), -i)
      end

    Enum.each(dates, fn date ->
      aggregate_date(date, dry_run)
    end)

    Mix.shell().info("\n✓ Backfill complete!")
  end

  defp aggregate_date(date, dry_run) do
    Mix.shell().info("\n📊 Aggregating #{date}...")

    # Get events for this date
    events = get_events_for_date(date)
    count = length(events)

    if count == 0 do
      Mix.shell().info("  No events found for #{date}")
      :ok
    else
      Mix.shell().info("  Found #{count} events")

      if dry_run do
        preview_aggregation(events, date)
      else
        do_aggregate(events, date)
      end
    end
  end

  defp get_events_for_date(date) do
    # Get start and end of day in UTC
    start_dt = DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
    end_dt = DateTime.new!(Date.add(date, 1), ~T[00:00:00], "Etc/UTC")

    from(d in DelayEvent,
      where: d.started_at >= ^start_dt and d.started_at < ^end_dt,
      select: %{
        lat: d.lat,
        lon: d.lon,
        line: d.line,
        classification: d.classification,
        duration_seconds: d.duration_seconds,
        near_intersection: d.near_intersection,
        started_at: d.started_at
      }
    )
    |> Repo.all()
  end

  defp preview_aggregation(events, date) do
    precision = Application.get_env(:waw_trams, :aggregation_precision, 4)

    # Preview intersection stats
    intersection_groups = group_by_location(events, precision)
    Mix.shell().info("  → Would create #{map_size(intersection_groups)} intersection stats")

    # Preview line stats
    line_groups = group_by_line(events)
    Mix.shell().info("  → Would create #{map_size(line_groups)} line stats")

    # Preview hourly patterns
    hourly_groups = group_by_hour_and_day(events, date)
    Mix.shell().info("  → Would update #{map_size(hourly_groups)} hourly pattern slots")

    Mix.shell().info("  (dry run - no changes made)")
  end

  defp do_aggregate(events, date) do
    precision = Application.get_env(:waw_trams, :aggregation_precision, 4)

    # 1. Aggregate by location
    intersection_count = aggregate_intersections(events, date, precision)
    Mix.shell().info("  ✓ Created #{intersection_count} intersection stats")

    # 2. Aggregate by line
    line_count = aggregate_lines(events, date)
    Mix.shell().info("  ✓ Created #{line_count} line stats")

    # 3. Update hourly patterns
    hourly_count = update_hourly_patterns(events, date)
    Mix.shell().info("  ✓ Updated #{hourly_count} hourly pattern slots")
  end

  # --- Intersection Aggregation ---

  defp aggregate_intersections(events, date, precision) do
    events
    |> Enum.filter(& &1.near_intersection)
    |> group_by_location(precision)
    |> Enum.map(fn {{lat, lon}, group_events} ->
      attrs = %{
        date: date,
        lat: lat,
        lon: lon,
        nearest_stop: find_nearest_stop(lat, lon),
        delay_count: count_by_classification(group_events, "delay"),
        blockage_count: count_by_classification(group_events, "blockage"),
        total_seconds: sum_duration(group_events),
        affected_lines: get_unique_lines(group_events)
      }

      DailyIntersectionStat.upsert!(attrs)
    end)
    |> length()
  end

  defp group_by_location(events, precision) do
    Enum.group_by(events, fn e ->
      {round_coord(e.lat, precision), round_coord(e.lon, precision)}
    end)
  end

  defp round_coord(coord, precision) do
    Float.round(coord, precision)
  end

  defp find_nearest_stop(lat, lon) do
    query = """
    SELECT name FROM stops
    WHERE NOT is_terminal
    ORDER BY geom::geography <-> ST_SetSRID(ST_MakePoint($1, $2), 4326)::geography
    LIMIT 1
    """

    case Repo.query(query, [lon, lat]) do
      {:ok, %{rows: [[name]]}} -> name
      _ -> nil
    end
  end

  # --- Line Aggregation ---

  defp aggregate_lines(events, date) do
    events
    |> group_by_line()
    |> Enum.map(fn {line, group_events} ->
      by_hour = build_by_hour(group_events)

      attrs = %{
        date: date,
        line: line,
        delay_count: count_by_classification(group_events, "delay"),
        blockage_count: count_by_classification(group_events, "blockage"),
        total_seconds: sum_duration(group_events),
        intersection_count: Enum.count(group_events, & &1.near_intersection),
        by_hour: by_hour
      }

      DailyLineStat.upsert!(attrs)
    end)
    |> length()
  end

  defp group_by_line(events) do
    events
    |> Enum.filter(& &1.line)
    |> Enum.group_by(& &1.line)
  end

  defp build_by_hour(events) do
    events
    |> Enum.group_by(fn e ->
      e.started_at.hour |> to_string()
    end)
    |> Enum.map(fn {hour, hour_events} ->
      {hour,
       %{
         "delay_count" => count_by_classification(hour_events, "delay"),
         "blockage_count" => count_by_classification(hour_events, "blockage"),
         "total_seconds" => sum_duration(hour_events),
         "intersection_delays" => Enum.count(hour_events, & &1.near_intersection)
       }}
    end)
    |> Map.new()
  end

  # --- Hourly Patterns ---

  defp update_hourly_patterns(events, date) do
    day_of_week = Date.day_of_week(date)

    events
    |> group_by_hour_and_day(date)
    |> Enum.map(fn {{_dow, hour}, group_events} ->
      delay_count = count_by_classification(group_events, "delay")
      blockage_count = count_by_classification(group_events, "blockage")
      total_seconds = sum_duration(group_events)

      HourlyPattern.increment!(day_of_week, hour, delay_count, blockage_count, total_seconds)
    end)
    |> length()
  end

  defp group_by_hour_and_day(events, date) do
    day_of_week = Date.day_of_week(date)

    Enum.group_by(events, fn e ->
      {day_of_week, e.started_at.hour}
    end)
  end

  # --- Helpers ---

  defp count_by_classification(events, classification) do
    Enum.count(events, &(&1.classification == classification))
  end

  defp sum_duration(events) do
    events
    |> Enum.map(& &1.duration_seconds)
    |> Enum.reject(&is_nil/1)
    |> Enum.sum()
  end

  defp get_unique_lines(events) do
    events
    |> Enum.map(& &1.line)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end
end
