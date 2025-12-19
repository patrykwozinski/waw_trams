defmodule WawTrams.HourlyAggregator do
  @moduledoc """
  Runs aggregation every hour to keep stats fresh.

  Aggregates the previous hour's delay events into:
  - `daily_intersection_stats` (additive upsert)
  - `daily_line_stats` (additive upsert)
  - `hourly_patterns` (increment counters)

  Runs at minute 5 of every hour to ensure all events from the
  previous hour have been recorded.

  Raw events are kept for 7 days (configurable) for debugging/recovery.
  """

  use GenServer
  require Logger

  alias WawTrams.{Repo, DelayEvent, DailyIntersectionStat, DailyLineStat, HourlyPattern, HourlyIntersectionStat}
  alias WawTrams.Audit.CostCalculator
  import Ecto.Query

  # Run 5 minutes after each hour
  @aggregation_minute 5

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Logger.info(
      "HourlyAggregator started, will run at minute #{@aggregation_minute} of each hour"
    )

    # Catch up any missed hours on startup (async to not block app start)
    Process.send_after(self(), :catch_up, 5_000)

    # Schedule normal hourly runs
    schedule_next_aggregation()

    {:ok, %{last_aggregated: nil, catching_up: false}}
  end

  @impl true
  def handle_info(:catch_up, state) do
    case catch_up_missed_hours() do
      {:ok, 0} ->
        Logger.debug("[HourlyAggregator] No missed hours to catch up")

      {:ok, count} ->
        Logger.info("[HourlyAggregator] Caught up #{count} missed hours on startup")
    end

    {:noreply, %{state | catching_up: false}}
  end

  @impl true
  def handle_info(:aggregate, state) do
    # Aggregate the previous hour
    now = DateTime.utc_now()
    previous_hour = DateTime.add(now, -1, :hour) |> DateTime.truncate(:second)

    case aggregate_hour(previous_hour) do
      {:ok, stats} ->
        Logger.info(
          "[HourlyAggregator] Aggregated #{stats.event_count} events for hour #{format_hour(previous_hour)}"
        )

        schedule_next_aggregation()
        {:noreply, %{state | last_aggregated: previous_hour}}

      {:error, reason} ->
        Logger.error("[HourlyAggregator] Failed to aggregate: #{inspect(reason)}")
        # Retry in 5 minutes
        Process.send_after(self(), :aggregate, :timer.minutes(5))
        {:noreply, state}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_call({:aggregate_now, hour}, _from, state) do
    result = aggregate_hour(hour)
    {:reply, result, state}
  end

  # --- Public API ---

  @doc """
  Returns the aggregator status.
  """
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @doc """
  Manually trigger aggregation for a specific hour.
  Useful for backfilling or testing.
  """
  def aggregate_now(hour \\ DateTime.add(DateTime.utc_now(), -1, :hour)) do
    GenServer.call(__MODULE__, {:aggregate_now, hour}, :timer.minutes(5))
  end

  # --- Internal ---

  defp schedule_next_aggregation do
    now = DateTime.utc_now()
    next_run = next_aggregation_time(now)
    delay_ms = DateTime.diff(next_run, now, :millisecond)

    Logger.debug("[HourlyAggregator] Next run at #{next_run} (in #{div(delay_ms, 1000)}s)")
    Process.send_after(self(), :aggregate, delay_ms)
  end

  defp next_aggregation_time(now) do
    current_minute = now.minute

    if current_minute < @aggregation_minute do
      # Run this hour at minute 5
      %{now | minute: @aggregation_minute, second: 0, microsecond: {0, 0}}
    else
      # Run next hour at minute 5
      now
      |> DateTime.add(1, :hour)
      |> Map.put(:minute, @aggregation_minute)
      |> Map.put(:second, 0)
      |> Map.put(:microsecond, {0, 0})
    end
  end

  defp aggregate_hour(hour_dt) do
    # Get hour boundaries
    hour_start = %{hour_dt | minute: 0, second: 0, microsecond: {0, 0}}
    hour_end = DateTime.add(hour_start, 1, :hour)
    date = DateTime.to_date(hour_start)
    day_of_week = Date.day_of_week(date)
    hour = hour_start.hour

    # Get events for this hour
    events = get_events_for_hour(hour_start, hour_end)
    event_count = length(events)

    if event_count == 0 do
      {:ok, %{event_count: 0, intersections: 0, lines: 0}}
    else
      precision = Application.get_env(:waw_trams, :aggregation_precision, 4)

      # Aggregate intersections (daily + hourly with cost)
      intersection_count = aggregate_intersections(events, date, precision)
      aggregate_hourly_intersections(events, date, hour, precision)

      # Aggregate lines
      line_count = aggregate_lines(events, date, hour)

      # Update hourly patterns
      update_hourly_pattern(events, day_of_week, hour)

      {:ok,
       %{
         event_count: event_count,
         intersections: intersection_count,
         lines: line_count
       }}
    end
  rescue
    e ->
      {:error, e}
  end

  defp get_events_for_hour(hour_start, hour_end) do
    from(d in DelayEvent,
      where: d.started_at >= ^hour_start and d.started_at < ^hour_end,
      select: %{
        lat: d.lat,
        lon: d.lon,
        line: d.line,
        classification: d.classification,
        duration_seconds: d.duration_seconds,
        near_intersection: d.near_intersection,
        multi_cycle: d.multi_cycle
      }
    )
    |> Repo.all()
  end

  defp aggregate_intersections(events, date, precision) do
    events
    |> Enum.filter(& &1.near_intersection)
    |> Enum.group_by(fn e ->
      {round_coord(e.lat, precision), round_coord(e.lon, precision)}
    end)
    |> Enum.map(fn {{lat, lon}, group_events} ->
      # Get or create the stat, then update additively
      existing = get_existing_intersection_stat(date, lat, lon)

      attrs = %{
        date: date,
        lat: lat,
        lon: lon,
        nearest_stop: existing[:nearest_stop] || find_nearest_stop(lat, lon),
        delay_count: (existing[:delay_count] || 0) + count_classification(group_events, "delay"),
        blockage_count:
          (existing[:blockage_count] || 0) + count_classification(group_events, "blockage"),
        total_seconds: (existing[:total_seconds] || 0) + sum_duration(group_events),
        affected_lines:
          merge_lines(existing[:affected_lines] || [], get_unique_lines(group_events))
      }

      DailyIntersectionStat.upsert!(attrs)
    end)
    |> length()
  end

  defp aggregate_hourly_intersections(events, date, hour, precision) do
    events
    |> Enum.filter(& &1.near_intersection)
    |> Enum.group_by(fn e ->
      {round_coord(e.lat, precision), round_coord(e.lon, precision)}
    end)
    |> Enum.each(fn {{lat, lon}, group_events} ->
      # Calculate cost for this hour's delays
      total_seconds = sum_duration(group_events)
      cost = CostCalculator.calculate(total_seconds, hour)

      attrs = %{
        date: date,
        hour: hour,
        lat: lat,
        lon: lon,
        delay_count: length(group_events),
        multi_cycle_count: Enum.count(group_events, & &1.multi_cycle),
        total_seconds: total_seconds,
        cost_pln: cost.total,
        lines: get_unique_lines(group_events)
      }

      HourlyIntersectionStat.upsert!(attrs)
    end)
  end

  defp get_existing_intersection_stat(date, lat, lon) do
    case Repo.get_by(DailyIntersectionStat, date: date, lat: lat, lon: lon) do
      nil ->
        %{}

      stat ->
        %{
          nearest_stop: stat.nearest_stop,
          delay_count: stat.delay_count,
          blockage_count: stat.blockage_count,
          total_seconds: stat.total_seconds,
          affected_lines: stat.affected_lines
        }
    end
  end

  defp aggregate_lines(events, date, hour) do
    events
    |> Enum.filter(& &1.line)
    |> Enum.group_by(& &1.line)
    |> Enum.map(fn {line, group_events} ->
      existing = get_existing_line_stat(date, line)

      hour_key = to_string(hour)
      new_hour_stats = build_hour_stats(group_events)
      merged_by_hour = merge_by_hour(existing[:by_hour] || %{}, hour_key, new_hour_stats)

      attrs = %{
        date: date,
        line: line,
        delay_count: (existing[:delay_count] || 0) + count_classification(group_events, "delay"),
        blockage_count:
          (existing[:blockage_count] || 0) + count_classification(group_events, "blockage"),
        total_seconds: (existing[:total_seconds] || 0) + sum_duration(group_events),
        intersection_count:
          (existing[:intersection_count] || 0) + Enum.count(group_events, & &1.near_intersection),
        by_hour: merged_by_hour
      }

      DailyLineStat.upsert!(attrs)
    end)
    |> length()
  end

  defp get_existing_line_stat(date, line) do
    case Repo.get_by(DailyLineStat, date: date, line: line) do
      nil ->
        %{}

      stat ->
        %{
          delay_count: stat.delay_count,
          blockage_count: stat.blockage_count,
          total_seconds: stat.total_seconds,
          intersection_count: stat.intersection_count,
          by_hour: stat.by_hour
        }
    end
  end

  defp build_hour_stats(events) do
    %{
      "delay_count" => count_classification(events, "delay"),
      "blockage_count" => count_classification(events, "blockage"),
      "total_seconds" => sum_duration(events),
      "intersection_delays" => Enum.count(events, & &1.near_intersection)
    }
  end

  defp merge_by_hour(existing_by_hour, hour_key, new_stats) do
    Map.update(existing_by_hour, hour_key, new_stats, fn existing ->
      %{
        "delay_count" => (existing["delay_count"] || 0) + new_stats["delay_count"],
        "blockage_count" => (existing["blockage_count"] || 0) + new_stats["blockage_count"],
        "total_seconds" => (existing["total_seconds"] || 0) + new_stats["total_seconds"],
        "intersection_delays" =>
          (existing["intersection_delays"] || 0) + (new_stats["intersection_delays"] || 0)
      }
    end)
  end

  defp update_hourly_pattern(events, day_of_week, hour) do
    delay_count = count_classification(events, "delay")
    blockage_count = count_classification(events, "blockage")
    total_seconds = sum_duration(events)

    HourlyPattern.increment!(day_of_week, hour, delay_count, blockage_count, total_seconds)
  end

  # --- Helpers ---

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

  defp count_classification(events, classification) do
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
  end

  defp merge_lines(existing, new) do
    (existing ++ new)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp format_hour(dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:00")
  end

  # --- Catch-up Logic ---

  # Catches up any missed hours since the last aggregation.
  # Looks back up to 24 hours for startup catch-up.
  defp catch_up_missed_hours do
    # Find hours with raw events that haven't been aggregated yet
    now = DateTime.utc_now()
    retention_days = Application.get_env(:waw_trams, :raw_retention_days, 7)

    # Look back up to retention period, but max 24 hours for startup catch-up
    lookback_hours = min(retention_days * 24, 24)
    earliest = DateTime.add(now, -lookback_hours, :hour)

    # Get hours with raw events
    hours_with_events = get_hours_with_raw_events(earliest, now)

    # Get hours already aggregated (from daily_line_stats updated_at)
    aggregated_hours = get_aggregated_hours(earliest, now)

    # Find missing hours
    missing_hours =
      hours_with_events
      |> Enum.reject(fn hour -> MapSet.member?(aggregated_hours, hour) end)
      # Don't aggregate current hour (incomplete)
      |> Enum.reject(fn hour -> hour.hour == now.hour and Date.compare(hour, now) == :eq end)
      |> Enum.sort(DateTime)

    if missing_hours == [] do
      {:ok, 0}
    else
      Logger.info(
        "[HourlyAggregator] Found #{length(missing_hours)} missed hours to catch up: #{inspect(Enum.map(missing_hours, &format_hour/1))}"
      )

      # Aggregate each missing hour
      results =
        Enum.map(missing_hours, fn hour ->
          case aggregate_hour(hour) do
            {:ok, stats} ->
              Logger.debug(
                "[HourlyAggregator] Caught up hour #{format_hour(hour)}: #{stats.event_count} events"
              )

              :ok

            {:error, reason} ->
              Logger.warning(
                "[HourlyAggregator] Failed to catch up #{format_hour(hour)}: #{inspect(reason)}"
              )

              :error
          end
        end)

      success_count = Enum.count(results, &(&1 == :ok))
      {:ok, success_count}
    end
  end

  defp get_hours_with_raw_events(earliest, latest) do
    query =
      from(d in DelayEvent,
        where: d.started_at >= ^earliest and d.started_at < ^latest,
        select:
          fragment(
            "date_trunc('hour', ?) AT TIME ZONE 'UTC'",
            d.started_at
          ),
        distinct: true
      )

    Repo.all(query)
    |> Enum.map(fn naive ->
      {:ok, dt} = DateTime.from_naive(naive, "Etc/UTC")
      dt
    end)
  end

  defp get_aggregated_hours(earliest, latest) do
    # Check daily_line_stats for hours that were aggregated
    # We use the by_hour JSONB keys to determine which hours are covered
    query =
      from(d in DailyLineStat,
        where: d.date >= ^DateTime.to_date(earliest) and d.date <= ^DateTime.to_date(latest),
        select: {d.date, d.by_hour}
      )

    Repo.all(query)
    |> Enum.flat_map(fn {date, by_hour} ->
      if by_hour do
        by_hour
        |> Map.keys()
        |> Enum.map(fn hour_str ->
          hour = String.to_integer(hour_str)
          {:ok, dt} = DateTime.new(date, Time.new!(hour, 0, 0), "Etc/UTC")
          dt
        end)
      else
        []
      end
    end)
    |> MapSet.new()
  end
end
