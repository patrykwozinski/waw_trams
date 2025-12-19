defmodule WawTrams.QueryRouter do
  @moduledoc """
  Routes analytics queries to raw events or aggregated tables.

  Strategy (with hourly aggregation):
  - **Always aggregated**: heatmap_grid (cumulative patterns)
  - **Prefer aggregated**: hot_spots, impacted_lines, delays_by_hour, line_summary
  - **Always raw**: active, recent (real-time feeds)

  Aggregated data is at most ~1 hour behind (aggregation runs at minute 5).
  """

  alias WawTrams.{DailyIntersectionStat, DailyLineStat, HourlyPattern}
  alias WawTrams.Queries.{ActiveDelays, HotSpots, LineAnalysis}

  # --- Aggregated + Real-time (consistent freshness) ---

  @doc """
  Returns hot spots from aggregated data + recent events since :05.
  """
  def hot_spots(opts \\ []) do
    aggregated = DailyIntersectionStat.hot_spots(to_date_opts(opts))

    if aggregated == [] do
      # Fallback to raw if no aggregated data yet
      HotSpots.hot_spots(opts)
    else
      # Add recent events (since minute 5)
      recent = get_recent_hot_spots()
      merge_hot_spots(aggregated, recent)
    end
  end

  @doc """
  Returns impacted lines from aggregated data + recent events since :05.
  """
  def impacted_lines(opts \\ []) do
    aggregated = DailyLineStat.impacted_lines(to_date_opts(opts))

    if aggregated == [] do
      HotSpots.impacted_lines(opts)
    else
      # Add recent events (since minute 5)
      recent = get_recent_impacted_lines()
      merge_impacted_lines(aggregated, recent)
    end
  end

  @doc """
  Returns delays by hour for a line.
  Uses aggregated data, adding only NEW events from current hour (not yet aggregated).
  """
  def delays_by_hour(line, opts \\ []) do
    aggregated = DailyLineStat.delays_by_hour(line, to_date_opts(opts))

    if aggregated == [] do
      # No aggregated data yet, use raw
      LineAnalysis.delays_by_hour(line, opts)
    else
      # Check if current hour is already aggregated
      current_hour = DateTime.utc_now().hour
      has_current_hour = Enum.any?(aggregated, &(&1.hour == current_hour))

      if has_current_hour do
        # Current hour already aggregated - only add events since last aggregation (last 5 min)
        recent_events = get_recent_events_stats(line, current_hour)
        merge_hour_data(aggregated, recent_events)
      else
        # Current hour not aggregated yet - add all current hour events
        current_hour_raw = get_current_hour_stats(line, current_hour)
        merge_hour_data(aggregated, current_hour_raw)
      end
    end
  end

  @doc """
  Returns line summary.
  Uses aggregated data, adding only NEW events since last aggregation.
  """
  def line_summary(line, opts \\ []) do
    aggregated = DailyLineStat.line_summary(line, to_date_opts(opts))

    # Get only recent events (since minute 5 of current hour)
    recent = get_recent_summary(line)

    if aggregated.total_delays == 0 and recent.total_delays == 0 do
      aggregated
    else
      %{
        total_delays: aggregated.total_delays + recent.total_delays,
        blockage_count: (aggregated[:blockage_count] || 0) + recent.blockage_count,
        total_seconds: aggregated.total_seconds + recent.total_seconds,
        intersection_delays: (aggregated[:intersection_delays] || 0) + recent.intersection_delays,
        avg_seconds:
          safe_avg(
            aggregated.total_seconds + recent.total_seconds,
            aggregated.total_delays + recent.total_delays +
              (aggregated[:blockage_count] || 0) + recent.blockage_count
          )
      }
    end
  end

  @doc """
  Returns heatmap grid - ALWAYS uses HourlyPattern (cumulative).
  """
  def heatmap_grid(_opts \\ []) do
    # HourlyPattern is cumulative, always has all historical data
    HourlyPattern.heatmap_grid()
  end

  @doc """
  Returns lines with recorded stats from aggregated data.
  """
  def lines_with_delays(opts \\ []) do
    result = DailyLineStat.lines_with_stats(to_date_opts(opts))

    if result == [] do
      LineAnalysis.lines_with_delays(opts)
    else
      result
    end
  end

  # --- Always use raw events (real-time) ---

  @doc """
  Active delays - always raw, real-time.
  """
  defdelegate active(), to: ActiveDelays

  @doc """
  Recent delays - always raw, recent events.
  """
  defdelegate recent(limit \\ 100), to: ActiveDelays

  @doc """
  Hot spot summary for dashboard (24h) - uses raw for freshness.
  """
  defdelegate hot_spot_summary(since \\ DateTime.add(DateTime.utc_now(), -24, :hour)),
    to: HotSpots

  @doc """
  Line hot spots - uses raw for clustering precision.
  """
  defdelegate line_hot_spots(line, opts \\ []), to: LineAnalysis, as: :hot_spots

  # --- Internal helpers ---

  # Convert DateTime opts to Date opts for aggregated queries
  defp to_date_opts(opts) do
    case Keyword.get(opts, :since) do
      %DateTime{} = dt ->
        Keyword.put(opts, :since, DateTime.to_date(dt))

      _ ->
        opts
    end
  end

  # Get recent events (since last aggregation at minute 5)
  # This avoids double-counting when current hour is already aggregated
  defp get_recent_events_stats(line, current_hour) do
    import Ecto.Query
    alias WawTrams.Repo
    alias WawTrams.DelayEvent

    # Aggregation runs at minute 5, so get events since then
    now = DateTime.utc_now()
    since = %{now | minute: 5, second: 0, microsecond: {0, 0}}

    # If we're before minute 5, no new events since aggregation
    if now.minute < 5 do
      %{
        hour: current_hour,
        delay_count: 0,
        blockage_count: 0,
        total_seconds: 0,
        intersection_delays: 0,
        avg_seconds: 0.0
      }
    else
      query =
        from(d in DelayEvent,
          where: d.line == ^line and d.started_at >= ^since,
          select: %{
            delay_count: sum(fragment("CASE WHEN classification = 'delay' THEN 1 ELSE 0 END")),
            blockage_count:
              sum(fragment("CASE WHEN classification = 'blockage' THEN 1 ELSE 0 END")),
            total_seconds: coalesce(sum(d.duration_seconds), 0),
            intersection_delays: sum(fragment("CASE WHEN near_intersection THEN 1 ELSE 0 END"))
          }
        )

      case Repo.one(query) do
        nil ->
          %{
            hour: current_hour,
            delay_count: 0,
            blockage_count: 0,
            total_seconds: 0,
            intersection_delays: 0,
            avg_seconds: 0.0
          }

        stats ->
          total = (stats.delay_count || 0) + (stats.blockage_count || 0)

          %{
            hour: current_hour,
            delay_count: stats.delay_count || 0,
            blockage_count: stats.blockage_count || 0,
            total_seconds: stats.total_seconds || 0,
            intersection_delays: stats.intersection_delays || 0,
            avg_seconds: safe_avg(stats.total_seconds, total)
          }
      end
    end
  end

  # Get current hour stats from raw events for a line
  defp get_current_hour_stats(line, current_hour) do
    import Ecto.Query
    alias WawTrams.Repo
    alias WawTrams.DelayEvent

    hour_start = DateTime.utc_now() |> Map.put(:minute, 0) |> Map.put(:second, 0)

    query =
      from(d in DelayEvent,
        where: d.line == ^line and d.started_at >= ^hour_start,
        select: %{
          delay_count: sum(fragment("CASE WHEN classification = 'delay' THEN 1 ELSE 0 END")),
          blockage_count:
            sum(fragment("CASE WHEN classification = 'blockage' THEN 1 ELSE 0 END")),
          total_seconds: coalesce(sum(d.duration_seconds), 0),
          intersection_delays: sum(fragment("CASE WHEN near_intersection THEN 1 ELSE 0 END"))
        }
      )

    case Repo.one(query) do
      nil ->
        %{
          hour: current_hour,
          delay_count: 0,
          blockage_count: 0,
          total_seconds: 0,
          intersection_delays: 0,
          avg_seconds: 0.0
        }

      stats ->
        total = (stats.delay_count || 0) + (stats.blockage_count || 0)

        %{
          hour: current_hour,
          delay_count: stats.delay_count || 0,
          blockage_count: stats.blockage_count || 0,
          total_seconds: stats.total_seconds || 0,
          intersection_delays: stats.intersection_delays || 0,
          avg_seconds: safe_avg(stats.total_seconds, total)
        }
    end
  end

  # Get summary for recent events only (since minute 5 of current hour)
  defp get_recent_summary(line) do
    import Ecto.Query
    alias WawTrams.Repo
    alias WawTrams.DelayEvent

    now = DateTime.utc_now()
    since = %{now | minute: 5, second: 0, microsecond: {0, 0}}

    # If before minute 5, aggregation hasn't run yet this hour
    if now.minute < 5 do
      %{total_delays: 0, blockage_count: 0, total_seconds: 0, intersection_delays: 0}
    else
      query =
        from(d in DelayEvent,
          where: d.line == ^line and d.started_at >= ^since,
          select: %{
            total_delays: count(d.id),
            blockage_count:
              sum(fragment("CASE WHEN classification = 'blockage' THEN 1 ELSE 0 END")),
            total_seconds: coalesce(sum(d.duration_seconds), 0),
            intersection_delays: sum(fragment("CASE WHEN near_intersection THEN 1 ELSE 0 END"))
          }
        )

      case Repo.one(query) do
        nil ->
          %{total_delays: 0, blockage_count: 0, total_seconds: 0, intersection_delays: 0}

        stats ->
          %{
            total_delays: stats.total_delays || 0,
            blockage_count: stats.blockage_count || 0,
            total_seconds: stats.total_seconds || 0,
            intersection_delays: stats.intersection_delays || 0
          }
      end
    end
  end

  # Merge aggregated hour data with current hour raw data
  defp merge_hour_data(aggregated, current_hour_raw) do
    current_hour = current_hour_raw.hour

    # Find if current hour exists in aggregated
    existing_idx = Enum.find_index(aggregated, &(&1.hour == current_hour))

    if existing_idx do
      # Update existing hour with fresh data
      List.update_at(aggregated, existing_idx, fn existing ->
        %{
          hour: current_hour,
          delay_count: existing.delay_count + current_hour_raw.delay_count,
          blockage_count: existing.blockage_count + current_hour_raw.blockage_count,
          total_seconds: existing.total_seconds + current_hour_raw.total_seconds,
          intersection_delays:
            existing.intersection_delays + current_hour_raw.intersection_delays,
          avg_seconds:
            safe_avg(
              existing.total_seconds + current_hour_raw.total_seconds,
              existing.delay_count + current_hour_raw.delay_count +
                existing.blockage_count + current_hour_raw.blockage_count
            )
        }
      end)
    else
      # Add current hour if not present
      if current_hour_raw.delay_count > 0 or current_hour_raw.blockage_count > 0 do
        (aggregated ++ [current_hour_raw])
        |> Enum.sort_by(& &1.hour)
      else
        aggregated
      end
    end
  end

  defp safe_avg(_, 0), do: 0.0
  defp safe_avg(nil, _), do: 0.0
  defp safe_avg(total, count), do: Float.round(total / count, 1)

  # --- Hot Spots Real-time Helpers ---

  # Get recent hot spot data (events since minute 5)
  defp get_recent_hot_spots do
    import Ecto.Query
    alias WawTrams.Repo
    alias WawTrams.DelayEvent

    now = DateTime.utc_now()

    if now.minute < 5 do
      []
    else
      since = %{now | minute: 5, second: 0, microsecond: {0, 0}}

      query =
        from(d in DelayEvent,
          where: d.started_at >= ^since and d.near_intersection == true,
          group_by: [
            fragment("ROUND(CAST(? AS numeric), 4)", d.lat),
            fragment("ROUND(CAST(? AS numeric), 4)", d.lon)
          ],
          select: %{
            lat: fragment("ROUND(CAST(? AS numeric), 4)", d.lat),
            lon: fragment("ROUND(CAST(? AS numeric), 4)", d.lon),
            delay_count: count(d.id),
            total_seconds: coalesce(sum(d.duration_seconds), 0)
          }
        )

      Repo.all(query)
    end
  end

  # Merge aggregated hot spots with recent events
  defp merge_hot_spots(aggregated, []), do: aggregated

  defp merge_hot_spots(aggregated, recent) do
    # Create a lookup by rounded lat/lon
    recent_lookup =
      Enum.reduce(recent, %{}, fn r, acc ->
        key = {round_coord(r.lat), round_coord(r.lon)}
        Map.put(acc, key, r)
      end)

    # Update aggregated with recent additions
    Enum.map(aggregated, fn spot ->
      key = {round_coord(spot.lat), round_coord(spot.lon)}

      case Map.get(recent_lookup, key) do
        nil ->
          spot

        recent ->
          %{
            spot
            | delay_count: spot.delay_count + recent.delay_count,
              total_seconds: spot.total_seconds + recent.total_seconds
          }
      end
    end)
  end

  # Round coordinate to 4 decimal places, handling Decimal
  defp round_coord(%Decimal{} = d), do: d |> Decimal.to_float() |> Float.round(4)
  defp round_coord(f) when is_float(f), do: Float.round(f, 4)
  defp round_coord(n), do: n

  # --- Impacted Lines Real-time Helpers ---

  # Get recent impacted lines data (events since minute 5)
  defp get_recent_impacted_lines do
    import Ecto.Query
    alias WawTrams.Repo
    alias WawTrams.DelayEvent

    now = DateTime.utc_now()

    if now.minute < 5 do
      []
    else
      since = %{now | minute: 5, second: 0, microsecond: {0, 0}}

      query =
        from(d in DelayEvent,
          where: d.started_at >= ^since and d.near_intersection == true,
          group_by: d.line,
          select: %{
            line: d.line,
            delay_count: count(d.id),
            total_seconds: coalesce(sum(d.duration_seconds), 0),
            blockage_count:
              sum(fragment("CASE WHEN classification = 'blockage' THEN 1 ELSE 0 END"))
          }
        )

      Repo.all(query)
    end
  end

  # Merge aggregated impacted lines with recent events
  defp merge_impacted_lines(aggregated, []), do: aggregated

  defp merge_impacted_lines(aggregated, recent) do
    recent_lookup = Map.new(recent, fn r -> {r.line, r} end)

    Enum.map(aggregated, fn line_data ->
      case Map.get(recent_lookup, line_data.line) do
        nil ->
          line_data

        recent ->
          new_total = line_data.total_seconds + recent.total_seconds
          new_delays = line_data.delay_count + recent.delay_count
          new_blockages = (line_data[:blockage_count] || 0) + (recent.blockage_count || 0)

          %{
            line_data
            | delay_count: new_delays,
              total_seconds: new_total,
              blockage_count: new_blockages,
              avg_seconds: safe_avg(new_total, new_delays + new_blockages)
          }
      end
    end)
    # Re-sort by total time since values changed
    |> Enum.sort_by(& &1.total_seconds, :desc)
  end
end
