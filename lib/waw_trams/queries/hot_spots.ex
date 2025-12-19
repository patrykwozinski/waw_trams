defmodule WawTrams.Queries.HotSpots do
  @moduledoc """
  Queries for intersection hot spot analysis.

  Identifies problematic intersections by clustering nearby delay events
  and ranking them by impact (delay count, total time lost).
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
      (
        SELECT s.name
        FROM stops s
        WHERE NOT s.is_terminal
        ORDER BY s.geom::geography <-> h.centroid::geography
        LIMIT 1
      ) as nearest_stop
    FROM hot_spot_data h
    ORDER BY h.delay_count DESC, h.total_delay_seconds DESC
    LIMIT $3
    """

    case Repo.query(query, [since, classification, limit]) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [cluster_id, osm_ids, lat, lon, count, total, avg, lines, stop_name] ->
          %{
            cluster_id: cluster_id,
            osm_ids: osm_ids,
            lat: lat,
            lon: lon,
            delay_count: count,
            total_delay_seconds: total,
            avg_delay_seconds: to_float(avg),
            affected_lines: Enum.reject(lines, &is_nil/1) |> Enum.sort(),
            nearest_stop: stop_name
          }
        end)

      {:error, _} ->
        []
    end
  end

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
