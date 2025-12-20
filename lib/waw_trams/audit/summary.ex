defmodule WawTrams.Audit.Summary do
  @moduledoc """
  City-wide summary statistics for the Audit Dashboard header.

  Provides the "shock value" numbers that grab attention.

  Uses aggregated data from `hourly_intersection_stats` for historical data,
  plus raw `delay_events` for the current hour (not yet aggregated).
  """

  import Ecto.Query

  alias WawTrams.{DelayEvent, Repo, HourlyIntersectionStat}
  alias WawTrams.Audit.CostCalculator

  @doc """
  Returns aggregate statistics for the header display.

  Uses the cache layer to reduce database load. For uncached access,
  use `stats_uncached/1`.

  ## Parameters
  - `opts` - Options:
    - `:since` - DateTime to filter from (default: last 7 days)
    - `:line` - Filter by specific tram line (default: all)

  ## Returns

  Map with:
  - `:total_delays` - Count of all delays
  - `:total_seconds` - Total delay time in seconds
  - `:total_hours` - Total delay time in hours (formatted)
  - `:cost` - Economic cost breakdown
  - `:multi_cycle_count` - Count of priority failures
  - `:intersection_count` - Number of affected intersections
  """
  def stats(opts \\ []) do
    WawTrams.Cache.get_audit_stats(opts)
  end

  @doc """
  Uncached version of stats/1. Used by the cache layer.
  """
  def stats_uncached(opts \\ []) do
    since = Keyword.get(opts, :since, DateTime.add(DateTime.utc_now(), -7, :day))
    line = Keyword.get(opts, :line, nil)

    # Pass DateTime directly - aggregate_stats handles partial days correctly
    agg_opts = [since: since]
    agg_opts = if line, do: Keyword.put(agg_opts, :line, line), else: agg_opts

    aggregated = HourlyIntersectionStat.aggregate_stats(agg_opts)

    # Get current hour raw events (not yet aggregated)
    current_hour_stats = get_current_hour_stats(line)

    # Combine
    total_delays = (aggregated.total_delays || 0) + current_hour_stats.delay_count
    total_seconds = (aggregated.total_seconds || 0) + current_hour_stats.total_seconds
    multi_cycle_count = (aggregated.multi_cycle_count || 0) + current_hour_stats.multi_cycle_count
    total_cost = (aggregated.total_cost || 0) + current_hour_stats.cost

    # Count unique intersection clusters
    intersection_count = HourlyIntersectionStat.count_intersections(agg_opts)

    total_hours = total_seconds / 3600

    %{
      total_delays: total_delays,
      blockage_count: current_hour_stats.blockage_count,
      total_seconds: total_seconds,
      total_hours: Float.round(total_hours, 1),
      total_hours_formatted: format_hours(total_hours),
      cost: %{
        total: Float.round(total_cost, 2),
        # Not tracked separately in aggregation
        passenger: 0.0,
        operational: 0.0,
        count: total_delays
      },
      multi_cycle_count: multi_cycle_count,
      intersection_count: intersection_count
    }
  end

  # Get stats from raw events not yet aggregated
  # The hourly aggregator runs at minute 5, so we need to include:
  # - Current hour (always not aggregated yet)
  # - Previous hour (if we're before minute 5)
  defp get_current_hour_stats(line) do
    now = DateTime.utc_now()
    current_hour_start = %{now | minute: 0, second: 0, microsecond: {0, 0}}

    # If before minute 5, include previous hour too (not yet aggregated)
    unaggregated_since =
      if now.minute < 5 do
        DateTime.add(current_hour_start, -1, :hour)
      else
        current_hour_start
      end

    base_query =
      from(d in DelayEvent,
        where: d.started_at >= ^unaggregated_since and d.near_intersection == true
      )

    base_query =
      if line do
        from(d in base_query, where: d.line == ^line)
      else
        base_query
      end

    stats =
      from(d in base_query,
        select: %{
          delay_count: count(d.id),
          multi_cycle_count: sum(fragment("CASE WHEN duration_seconds > 120 THEN 1 ELSE 0 END")),
          blockage_count:
            sum(fragment("CASE WHEN classification = 'blockage' THEN 1 ELSE 0 END")),
          total_seconds: coalesce(sum(d.duration_seconds), 0)
        }
      )
      |> Repo.one() ||
        %{delay_count: 0, multi_cycle_count: 0, blockage_count: 0, total_seconds: 0}

    # Use current hour for cost calculation (approximate)
    cost = CostCalculator.calculate(stats.total_seconds || 0, now.hour)

    %{
      delay_count: stats.delay_count || 0,
      multi_cycle_count: stats.multi_cycle_count || 0,
      blockage_count: stats.blockage_count || 0,
      total_seconds: stats.total_seconds || 0,
      cost: cost.total
    }
  end

  @doc """
  Returns leaderboard of worst intersections by cost.

  Uses the cache layer to reduce database load. For uncached access,
  use `leaderboard_uncached/1`.

  ## Parameters
  - `opts` - Options:
    - `:since` - DateTime to filter from (default: last 7 days)
    - `:limit` - Number of results (default: 10)
    - `:line` - Filter by specific tram line (default: all)

  ## Returns

  List of maps with:
  - `:lat`, `:lon` - Cluster centroid
  - `:location_name` - Name of nearest stop
  - `:cost` - Economic cost (PLN)
  - `:delay_count` - Number of delays
  - `:multi_cycle_count` - Priority failures
  - `:multi_cycle_pct` - Percentage of multi-cycle
  - `:severity` - :red, :orange, or :yellow based on multi_cycle_pct
  """
  def leaderboard(opts \\ []) do
    WawTrams.Cache.get_audit_leaderboard(opts)
  end

  @doc """
  Uncached version of leaderboard/1. Used by the cache layer.
  """
  def leaderboard_uncached(opts \\ []) do
    since = Keyword.get(opts, :since, DateTime.add(DateTime.utc_now(), -7, :day))
    limit = Keyword.get(opts, :limit, 10)
    line = Keyword.get(opts, :line, nil)

    # Extract date and hour for proper partial-day filtering
    {since_date, since_hour} =
      case since do
        %DateTime{} = dt -> {DateTime.to_date(dt), dt.hour}
        %Date{} = d -> {d, 0}
      end

    # Calculate unaggregated period (same logic as get_current_hour_stats)
    now = DateTime.utc_now()
    current_hour_start = %{now | minute: 0, second: 0, microsecond: {0, 0}}

    unaggregated_since =
      if now.minute < 5 do
        DateTime.add(current_hour_start, -1, :hour)
      else
        current_hour_start
      end

    # Use spatial clustering to group nearby points (~55m radius)
    # This handles cases where the same physical intersection has slightly different coordinates
    line_filter_agg = if line, do: "AND $5 = ANY(h.lines)", else: ""
    line_filter_raw = if line, do: "AND d.line = $5", else: ""

    # Combined query: aggregated data + current hour raw events
    query = """
    WITH hourly_points AS (
      -- Aggregated data from hourly_intersection_stats
      SELECT
        lat,
        lon,
        delay_count,
        multi_cycle_count,
        total_seconds,
        cost_pln,
        ST_SetSRID(ST_MakePoint(lon, lat), 4326) as geom
      FROM hourly_intersection_stats h
      WHERE (date > $1 OR (date = $1 AND hour >= $3))
        #{line_filter_agg}

      UNION ALL

      -- Current hour raw events (not yet aggregated)
      SELECT
        ROUND(d.lat::numeric, 4)::float as lat,
        ROUND(d.lon::numeric, 4)::float as lon,
        1 as delay_count,
        CASE WHEN d.duration_seconds > 120 THEN 1 ELSE 0 END as multi_cycle_count,
        COALESCE(d.duration_seconds, 60) as total_seconds,
        CASE
          WHEN EXTRACT(HOUR FROM d.started_at) BETWEEN 7 AND 9 THEN COALESCE(d.duration_seconds, 60) * 0.15
          WHEN EXTRACT(HOUR FROM d.started_at) BETWEEN 15 AND 18 THEN COALESCE(d.duration_seconds, 60) * 0.15
          ELSE COALESCE(d.duration_seconds, 60) * 0.08
        END as cost_pln,
        ST_SetSRID(ST_MakePoint(d.lon, d.lat), 4326) as geom
      FROM delay_events d
      WHERE d.started_at >= $4
        AND d.near_intersection = true
        #{line_filter_raw}
    ),
    clustered AS (
      SELECT
        lat,
        lon,
        delay_count,
        multi_cycle_count,
        total_seconds,
        cost_pln,
        geom,
        ST_ClusterDBSCAN(geom::geometry, eps := 0.001, minpoints := 1) OVER () as cluster_id
      FROM hourly_points
    ),
    cluster_stats AS (
      SELECT
        cluster_id,
        ST_Y(ST_Centroid(ST_Collect(geom))) as lat,
        ST_X(ST_Centroid(ST_Collect(geom))) as lon,
        SUM(delay_count) as delay_count,
        SUM(multi_cycle_count) as multi_cycle_count,
        SUM(total_seconds) as total_seconds,
        SUM(cost_pln) as cost_pln
      FROM clustered
      GROUP BY cluster_id
    )
    SELECT
      cs.lat,
      cs.lon,
      cs.delay_count,
      cs.multi_cycle_count,
      cs.total_seconds,
      cs.cost_pln,
      COALESCE(loc.intersection_name, loc.stop_name) as location_name,
      loc.intersection_name IS NOT NULL as is_intersection
    FROM cluster_stats cs
    CROSS JOIN LATERAL (
      SELECT
        (SELECT i.name FROM intersections i
         WHERE i.name IS NOT NULL AND i.name != ''
           AND ST_DWithin(i.geom::geography, ST_SetSRID(ST_MakePoint(cs.lon, cs.lat), 4326)::geography, 100)
         ORDER BY i.geom::geography <-> ST_SetSRID(ST_MakePoint(cs.lon, cs.lat), 4326)::geography
         LIMIT 1) as intersection_name,
        (SELECT s.name FROM stops s
         WHERE NOT s.is_terminal
           AND ST_DWithin(s.geom::geography, ST_SetSRID(ST_MakePoint(cs.lon, cs.lat), 4326)::geography, 500)
         ORDER BY s.geom::geography <-> ST_SetSRID(ST_MakePoint(cs.lon, cs.lat), 4326)::geography
         LIMIT 1) as stop_name
    ) loc
    ORDER BY cs.cost_pln DESC
    LIMIT $2
    """

    # Params: $1=since_date, $2=limit, $3=since_hour, $4=unaggregated_since, $5=line (optional)
    params =
      if line,
        do: [since_date, limit, since_hour, unaggregated_since, line],
        else: [since_date, limit, since_hour, unaggregated_since]

    case Repo.query(query, params) do
      {:ok, %{rows: rows}} ->
        rows
        |> Enum.with_index(1)
        |> Enum.map(fn {[lat, lon, count, multi, total_sec, cost, stop_name, is_intersection],
                        rank} ->
          count = count || 0
          multi = multi || 0

          multi_pct =
            if count > 0, do: Float.round(multi / count * 100, 1), else: 0.0

          %{
            lat: lat,
            lon: lon,
            delay_count: count,
            multi_cycle_count: multi,
            multi_cycle_pct: multi_pct,
            total_seconds: total_sec || 0,
            cost: %{total: Float.round((cost || 0) * 1.0, 2)},
            location_name: stop_name,
            is_intersection: is_intersection,
            severity: severity_from_rank(rank)
          }
        end)

      {:error, _} ->
        []
    end
  end

  # Determine severity color based on leaderboard position (by cost)
  # Top 3 = red (worst), 4-7 = orange, 8+ = yellow
  defp severity_from_rank(rank) when rank <= 3, do: :red
  defp severity_from_rank(rank) when rank <= 7, do: :orange
  defp severity_from_rank(_rank), do: :yellow

  # Format hours nicely as human-readable time
  defp format_hours(hours) when hours >= 1000 do
    "#{Float.round(hours / 1000, 1)}Kh"
  end

  defp format_hours(hours) when hours >= 1 do
    h = trunc(hours)
    m = trunc((hours - h) * 60)
    if m > 0, do: "#{h}h #{m}m", else: "#{h}h"
  end

  defp format_hours(hours) when hours > 0 do
    minutes = trunc(hours * 60)
    if minutes > 0, do: "#{minutes}m", else: "<1m"
  end

  defp format_hours(_), do: "0m"
end
