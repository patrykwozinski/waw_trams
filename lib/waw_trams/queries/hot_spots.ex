defmodule WawTrams.Queries.HotSpots do
  @moduledoc """
  Queries for intersection hot spot analysis.

  Identifies problematic intersections by clustering nearby delay events
  and ranking them by impact (delay count, total time lost).

  ## Performance

  - `hot_spots/1` - Uses raw `delay_events` with expensive spatial clustering (~300ms)
  - `hot_spots_fast/1` - Uses pre-aggregated `hourly_intersection_stats` (~20ms)

  Dashboard uses `hot_spots_fast/1` for better performance at scale.
  """

  import Ecto.Query

  alias WawTrams.DelayEvent
  alias WawTrams.Repo

  @doc """
  Returns top problematic intersections ranked by delay count.

  Clusters nearby intersection nodes (within ~55m) to treat them as one
  physical intersection, then ranks by:
  - Total delay count
  - Total delay time
  - Average delay duration

  Options:
  - `:since` - DateTime to filter from (default: last 24h)
  - `:limit` - Max results (default: 20)
  - `:classification` - Filter by "delay" or "blockage" (default: "delay")
  """
  def hot_spots(opts \\ []) do
    since = Keyword.get(opts, :since, DateTime.add(DateTime.utc_now(), -24, :hour))
    limit = Keyword.get(opts, :limit, 20)
    classification = Keyword.get(opts, :classification, "delay")

    query = """
    WITH clustered_intersections AS (
      SELECT
        osm_id,
        geom,
        ST_ClusterDBSCAN(geom::geometry, eps := 0.0005, minpoints := 1) OVER () as cluster_id
      FROM intersections
    ),
    cluster_centroids AS (
      SELECT
        cluster_id,
        ST_Centroid(ST_Collect(geom)) as centroid,
        array_agg(osm_id) as osm_ids
      FROM clustered_intersections
      GROUP BY cluster_id
    ),
    hot_spot_data AS (
      SELECT
        c.cluster_id,
        c.osm_ids,
        c.centroid,
        ST_Y(c.centroid) as lat,
        ST_X(c.centroid) as lon,
        COUNT(d.id) as delay_count,
        COALESCE(SUM(d.duration_seconds), 0) as total_delay_seconds,
        COALESCE(AVG(d.duration_seconds), 0) as avg_delay_seconds,
        array_agg(DISTINCT d.line) as affected_lines
      FROM delay_events d
      JOIN cluster_centroids c ON ST_DWithin(
        c.centroid::geography,
        ST_SetSRID(ST_MakePoint(d.lon, d.lat), 4326)::geography,
        50
      )
      WHERE d.started_at >= $1
        AND d.classification = $2
        AND d.near_intersection = true
      GROUP BY c.cluster_id, c.osm_ids, c.centroid
    )
    SELECT
      h.cluster_id,
      h.osm_ids,
      h.lat,
      h.lon,
      h.delay_count,
      h.total_delay_seconds,
      h.avg_delay_seconds,
      h.affected_lines,
      COALESCE(loc.intersection_name, loc.stop_name) as location_name,
      loc.intersection_name IS NOT NULL as is_intersection
    FROM hot_spot_data h
    CROSS JOIN LATERAL (
      SELECT
        (SELECT i.name FROM intersections i
         WHERE i.name IS NOT NULL AND i.name != ''
           AND ST_DWithin(i.geom::geography, h.centroid::geography, 100)
         ORDER BY i.geom::geography <-> h.centroid::geography
         LIMIT 1) as intersection_name,
        (SELECT s.name FROM stops s
         WHERE NOT s.is_terminal
           AND ST_DWithin(s.geom::geography, h.centroid::geography, 500)
         ORDER BY s.geom::geography <-> h.centroid::geography
         LIMIT 1) as stop_name
    ) loc
    ORDER BY h.delay_count DESC, h.total_delay_seconds DESC
    LIMIT $3
    """

    case Repo.query(query, [since, classification, limit]) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [
                            cluster_id,
                            osm_ids,
                            lat,
                            lon,
                            count,
                            total,
                            avg,
                            lines,
                            stop_name,
                            is_intersection
                          ] ->
          %{
            cluster_id: cluster_id,
            osm_ids: osm_ids,
            lat: lat,
            lon: lon,
            delay_count: count,
            total_delay_seconds: total,
            avg_delay_seconds: to_float(avg),
            affected_lines: Enum.reject(lines, &is_nil/1) |> Enum.sort(),
            location_name: stop_name,
            is_intersection: is_intersection
          }
        end)

      {:error, _} ->
        []
    end
  end

  @spec hot_spot_summary() :: %{
          intersection_count: any(),
          total_delay_minutes: integer(),
          total_delay_seconds: false | nil | integer(),
          total_delays: any()
        }
  @doc """
  Returns summary of hot spot data for quick overview.
  Counts clustered intersections (not individual OSM nodes).
  """
  def hot_spot_summary(since \\ DateTime.add(DateTime.utc_now(), -24, :hour)) do
    query = """
    WITH clustered_intersections AS (
      SELECT
        geom,
        ST_ClusterDBSCAN(geom::geometry, eps := 0.0005, minpoints := 1) OVER () as cluster_id
      FROM intersections
    ),
    cluster_centroids AS (
      SELECT
        cluster_id,
        ST_Centroid(ST_Collect(geom)) as centroid
      FROM clustered_intersections
      GROUP BY cluster_id
    )
    SELECT
      COUNT(DISTINCT c.cluster_id) as intersection_count,
      COUNT(d.id) as total_delays,
      COALESCE(SUM(d.duration_seconds), 0) as total_delay_seconds
    FROM delay_events d
    JOIN cluster_centroids c ON ST_DWithin(
      c.centroid::geography,
      ST_SetSRID(ST_MakePoint(d.lon, d.lat), 4326)::geography,
      50
    )
    WHERE d.started_at >= $1
      AND d.classification = 'delay'
      AND d.near_intersection = true
    """

    case Repo.query(query, [since]) do
      {:ok, %{rows: [[count, delays, seconds]]}} ->
        %{
          intersection_count: count || 0,
          total_delays: delays || 0,
          total_delay_seconds: seconds || 0,
          total_delay_minutes: div(seconds || 0, 60)
        }

      _ ->
        %{intersection_count: 0, total_delays: 0, total_delay_seconds: 0, total_delay_minutes: 0}
    end
  end

  @doc """
  Returns delays at a specific intersection cluster (by cluster_id from clustered/1).
  """
  def delays_at_cluster(cluster_id, opts \\ []) do
    since = Keyword.get(opts, :since, DateTime.add(DateTime.utc_now(), -24, :hour))
    limit = Keyword.get(opts, :limit, 50)

    query = """
    WITH clustered_intersections AS (
      SELECT
        osm_id,
        geom,
        ST_ClusterDBSCAN(geom::geometry, eps := 0.0005, minpoints := 1) OVER () as cluster_id
      FROM intersections
    ),
    cluster_centroids AS (
      SELECT
        cluster_id,
        ST_Centroid(ST_Collect(geom)) as centroid
      FROM clustered_intersections
      GROUP BY cluster_id
    )
    SELECT
      d.id, d.vehicle_id, d.line, d.lat, d.lon,
      d.started_at, d.resolved_at, d.duration_seconds, d.classification
    FROM delay_events d
    JOIN cluster_centroids c ON ST_DWithin(
      c.centroid::geography,
      ST_SetSRID(ST_MakePoint(d.lon, d.lat), 4326)::geography,
      50
    )
    WHERE c.cluster_id = $1
      AND d.started_at >= $2
    ORDER BY d.started_at DESC
    LIMIT $3
    """

    case Repo.query(query, [cluster_id, since, limit]) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [
                            id,
                            vehicle_id,
                            line,
                            lat,
                            lon,
                            started_at,
                            resolved_at,
                            duration,
                            classification
                          ] ->
          %{
            id: id,
            vehicle_id: vehicle_id,
            line: line,
            lat: lat,
            lon: lon,
            started_at: started_at,
            resolved_at: resolved_at,
            duration_seconds: duration,
            classification: classification
          }
        end)

      {:error, _} ->
        []
    end
  end

  @doc """
  Fast version of hot_spots using pre-aggregated hourly_intersection_stats.

  ~15x faster than hot_spots/1 because it skips raw event clustering.
  Used by Dashboard for better performance at scale.

  Options:
  - `:since` - DateTime to filter from (default: last 24h)
  - `:limit` - Max results (default: 20)
  """
  def hot_spots_fast(opts \\ []) do
    since = Keyword.get(opts, :since, DateTime.add(DateTime.utc_now(), -24, :hour))
    limit = Keyword.get(opts, :limit, 20)

    # Extract date and hour for proper partial-day filtering
    {since_date, since_hour} =
      case since do
        %DateTime{} = dt -> {DateTime.to_date(dt), dt.hour}
        %Date{} = d -> {d, 0}
      end

    query = """
    WITH hourly_points AS (
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
      cs.total_seconds,
      cs.multi_cycle_count,
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
    ORDER BY cs.delay_count DESC, cs.total_seconds DESC
    LIMIT $2
    """

    case Repo.query(query, [since_date, limit, since_hour]) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [lat, lon, count, total, multi, stop_name, is_intersection] ->
          %{
            lat: lat,
            lon: lon,
            delay_count: count || 0,
            total_delay_seconds: total || 0,
            avg_delay_seconds:
              if(count && count > 0, do: Float.round((total || 0) / count, 1), else: 0.0),
            multi_cycle_count: multi || 0,
            location_name: stop_name,
            is_intersection: is_intersection
          }
        end)

      {:error, _} ->
        []
    end
  end

  @doc """
  Fast version of hot_spot_summary using pre-aggregated data.

  Returns summary of hot spot data for quick overview.
  """
  def hot_spot_summary_fast(opts \\ []) do
    since = Keyword.get(opts, :since, DateTime.add(DateTime.utc_now(), -24, :hour))

    # Extract date and hour for proper partial-day filtering
    {since_date, since_hour} =
      case since do
        %DateTime{} = dt -> {DateTime.to_date(dt), dt.hour}
        %Date{} = d -> {d, 0}
      end

    query = """
    SELECT
      COUNT(DISTINCT (lat, lon)) as intersection_count,
      COALESCE(SUM(delay_count), 0) as total_delays,
      COALESCE(SUM(total_seconds), 0) as total_delay_seconds
    FROM hourly_intersection_stats
    WHERE (date > $1 OR (date = $1 AND hour >= $2))
    """

    case Repo.query(query, [since_date, since_hour]) do
      {:ok, %{rows: [[count, delays, seconds]]}} ->
        %{
          intersection_count: count || 0,
          total_delays: delays || 0,
          total_delay_seconds: seconds || 0,
          total_delay_minutes: div(seconds || 0, 60)
        }

      _ ->
        %{intersection_count: 0, total_delays: 0, total_delay_seconds: 0, total_delay_minutes: 0}
    end
  end

  @doc """
  Returns tram lines ranked by intersection delay impact.
  """
  def impacted_lines(opts \\ []) do
    since = Keyword.get(opts, :since, DateTime.add(DateTime.utc_now(), -24, :hour))
    limit = Keyword.get(opts, :limit, 10)

    query =
      from d in DelayEvent,
        where: d.started_at >= ^since and d.near_intersection == true,
        group_by: d.line,
        select: %{
          line: d.line,
          delay_count: count(d.id),
          total_seconds: sum(d.duration_seconds),
          avg_seconds: avg(d.duration_seconds),
          blockage_count: sum(fragment("CASE WHEN classification = 'blockage' THEN 1 ELSE 0 END"))
        },
        order_by: [desc: sum(d.duration_seconds)],
        limit: ^limit

    query
    |> Repo.all()
    |> Enum.map(fn row ->
      %{
        line: row.line,
        delay_count: row.delay_count,
        total_seconds: row.total_seconds || 0,
        avg_seconds: to_float(row.avg_seconds),
        blockage_count: row.blockage_count || 0
      }
    end)
  end

  # Helper to safely convert Decimal/nil to float
  defp to_float(nil), do: 0.0
  defp to_float(%Decimal{} = d), do: Decimal.to_float(d) |> Float.round(1)
  defp to_float(n) when is_number(n), do: Float.round(n * 1.0, 1)
end
