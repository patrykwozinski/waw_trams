defmodule WawTrams.Audit.Intersection do
  @moduledoc """
  Detailed analytics for individual intersection hot spots.

  Provides deep-dive data for the Report Card view in the Audit Dashboard.

  Uses aggregated data from `hourly_intersection_stats` for historical data,
  plus raw `delay_events` for the current hour (not yet aggregated).
  """

  import Ecto.Query

  alias WawTrams.{DelayEvent, Repo, HourlyIntersectionStat}
  alias WawTrams.Audit.CostCalculator

  @doc """
  Returns detailed summary for a single intersection cluster.

  Uses aggregated data for historical periods, plus raw events for current hour.

  ## Parameters
  - `lat` - Latitude of cluster centroid
  - `lon` - Longitude of cluster centroid
  - `opts` - Options:
    - `:since` - DateTime to filter from (default: last 7 days)

  ## Returns

  Map with:
  - `:delay_count` - Number of delays
  - `:total_seconds` - Total delay time
  - `:multi_cycle_count` - Count of priority failures (>120s)
  - `:multi_cycle_pct` - Percentage of multi-cycle delays
  - `:cost` - Economic cost breakdown
  - `:affected_lines` - List of tram lines affected
  - `:nearest_stop` - Name of nearest stop
  """
  def summary(lat, lon, opts \\ []) do
    since = Keyword.get(opts, :since, DateTime.add(DateTime.utc_now(), -7, :day))
    since_date = DateTime.to_date(since)

    # Get aggregated stats
    aggregated = HourlyIntersectionStat.intersection_stats(lat, lon, since: since_date)

    # Get current hour raw events
    current_hour = get_current_hour_intersection_stats(lat, lon)

    # Combine
    delay_count = (aggregated.delay_count || 0) + current_hour.delay_count
    multi_cycle_count = (aggregated.multi_cycle_count || 0) + current_hour.multi_cycle_count
    total_seconds = (aggregated.total_seconds || 0) + current_hour.total_seconds
    total_cost = (aggregated.cost_pln || 0) + current_hour.cost

    multi_pct =
      if delay_count > 0, do: Float.round(multi_cycle_count / delay_count * 100, 1), else: 0.0

    # Get affected lines and nearest stop from raw query (more complete)
    {lines, stop_name} = get_intersection_metadata(lat, lon, since)

    %{
      delay_count: delay_count,
      blockage_count: current_hour.blockage_count,
      total_seconds: total_seconds,
      multi_cycle_count: multi_cycle_count,
      multi_cycle_pct: multi_pct,
      cost: %{
        total: Float.round(total_cost, 2),
        passenger: 0.0,
        operational: 0.0,
        count: delay_count
      },
      affected_lines: lines,
      nearest_stop: stop_name
    }
  end

  # Get current hour stats for an intersection
  # Uses spatial proximity (~110m) to match cluster centroids
  defp get_current_hour_intersection_stats(lat, lon) do
    now = DateTime.utc_now()
    hour_start = %{now | minute: 0, second: 0, microsecond: {0, 0}}
    hour = now.hour

    # Use spatial proximity to match any points within ~110m of the centroid
    query = """
    SELECT
      COUNT(*) as delay_count,
      COALESCE(SUM(CASE WHEN duration_seconds > 120 THEN 1 ELSE 0 END), 0) as multi_cycle_count,
      COALESCE(SUM(CASE WHEN classification = 'blockage' THEN 1 ELSE 0 END), 0) as blockage_count,
      COALESCE(SUM(duration_seconds), 0) as total_seconds
    FROM delay_events
    WHERE started_at >= $1
      AND ST_DWithin(
        ST_SetSRID(ST_MakePoint(lon, lat), 4326)::geography,
        ST_SetSRID(ST_MakePoint($2, $3), 4326)::geography,
        110
      )
    """

    stats =
      case Repo.query(query, [hour_start, lon, lat]) do
        {:ok, %{rows: [[count, multi, blockage, total]]}} ->
          %{
            delay_count: count || 0,
            multi_cycle_count: multi || 0,
            blockage_count: blockage || 0,
            total_seconds: total || 0
          }

        _ ->
          %{delay_count: 0, multi_cycle_count: 0, blockage_count: 0, total_seconds: 0}
      end

    cost = CostCalculator.calculate(stats.total_seconds || 0, hour)

    Map.put(stats, :cost, cost.total)
  end

  @doc """
  Returns metadata for an intersection (affected lines, nearest stop).
  Uses spatial proximity (~110m) to match cluster centroids.
  """
  def get_metadata(lat, lon, opts \\ []) do
    since = Keyword.get(opts, :since, DateTime.add(DateTime.utc_now(), -7, :day))
    get_intersection_metadata(lat, lon, since)
  end

  # Get metadata for an intersection (lines, stop name)
  # Uses spatial proximity (~110m) to match cluster centroids
  defp get_intersection_metadata(lat, lon, since) do
    query = """
    SELECT
      array_agg(DISTINCT line) as lines,
      (
        SELECT s.name
        FROM stops s
        WHERE NOT s.is_terminal
        ORDER BY s.geom::geography <-> ST_SetSRID(ST_MakePoint($2, $1), 4326)::geography
        LIMIT 1
      ) as nearest_stop
    FROM delay_events d
    WHERE d.started_at >= $3
      AND ST_DWithin(
        ST_SetSRID(ST_MakePoint(d.lon, d.lat), 4326)::geography,
        ST_SetSRID(ST_MakePoint($2, $1), 4326)::geography,
        110
      )
    """

    case Repo.query(query, [lat, lon, since]) do
      {:ok, %{rows: [[lines, stop_name]]}} ->
        {(lines || []) |> Enum.reject(&is_nil/1) |> Enum.sort(), stop_name}

      _ ->
        {[], nil}
    end
  end

  @doc """
  Returns hour×day heatmap data for a single intersection.

  Uses aggregated data from `hourly_intersection_stats`.

  ## Parameters
  - `lat` - Latitude of cluster centroid
  - `lon` - Longitude of cluster centroid
  - `opts` - Options:
    - `:since` - DateTime to filter from (default: last 7 days)

  ## Returns

  Map with:
  - `:grid` - List of hour rows, each with cells for each day
  - `:max_count` - Maximum delay count (for color scaling)
  - `:total_delays` - Total delays in the heatmap
  """
  def heatmap(lat, lon, opts \\ []) do
    since = Keyword.get(opts, :since, DateTime.add(DateTime.utc_now(), -7, :day))
    since_date = DateTime.to_date(since)

    raw_data = HourlyIntersectionStat.intersection_heatmap(lat, lon, since: since_date)

    build_grid(raw_data)
  end

  @doc """
  Returns recent delays at a specific intersection for detail view.
  """
  def recent_delays(lat, lon, opts \\ []) do
    since = Keyword.get(opts, :since, DateTime.add(DateTime.utc_now(), -7, :day))
    limit = Keyword.get(opts, :limit, 20)
    lat_rounded = Float.round(lat, 4)
    lon_rounded = Float.round(lon, 4)

    from(d in DelayEvent,
      where:
        d.started_at >= ^since and
          fragment("ROUND(CAST(? AS numeric), 4) = ?", d.lat, ^lat_rounded) and
          fragment("ROUND(CAST(? AS numeric), 4) = ?", d.lon, ^lon_rounded),
      order_by: [desc: d.started_at],
      limit: ^limit
    )
    |> Repo.all()
  end

  # Build heatmap grid structure
  defp build_grid(raw_data) do
    lookup =
      Enum.reduce(raw_data, %{}, fn %{day_of_week: dow, hour: h} = row, acc ->
        Map.put(acc, {dow, h}, row)
      end)

    max_count = raw_data |> Enum.map(& &1.delay_count) |> Enum.max(fn -> 1 end)

    grid =
      for hour <- 5..23 do
        cells =
          for day <- 1..7 do
            case Map.get(lookup, {day, hour}) do
              nil ->
                %{day: day, hour: hour, count: 0, total: 0, intensity: 0}

              row ->
                %{
                  day: row.day_of_week,
                  hour: row.hour,
                  count: row.delay_count,
                  total: row.total_seconds,
                  intensity: Float.round(row.delay_count / max_count, 2)
                }
            end
          end

        %{hour: hour, cells: cells}
      end

    %{
      grid: grid,
      max_count: max_count,
      total_delays: Enum.sum(Enum.map(raw_data, & &1.delay_count))
    }
  end
end
