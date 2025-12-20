defmodule WawTrams.Queries.LineAnalysis do
  @moduledoc """
  Functions for analyzing delay patterns for specific tram lines.

  Provides per-line statistics, hourly breakdowns, and hot spot
  identification for targeted analysis.
  """

  import Ecto.Query

  alias WawTrams.DelayEvent
  alias WawTrams.Repo

  # Helper to safely convert Decimal/nil to float
  defp to_float(nil), do: 0.0
  defp to_float(%Decimal{} = d), do: Decimal.to_float(d) |> Float.round(1)
  defp to_float(n) when is_number(n), do: Float.round(n * 1.0, 1)

  # Helper to safely convert Decimal/nil to integer
  defp to_int(nil), do: 0
  defp to_int(%Decimal{} = d), do: Decimal.to_integer(d)
  defp to_int(n) when is_number(n), do: trunc(n)

  @doc """
  Returns delays grouped by hour of day for a specific line.
  Useful for identifying worst commute times.

  ## Options
  - `:since` - DateTime to filter from (default: last 7 days)

  ## Example

      iex> LineAnalysis.delays_by_hour("19")
      [
        %{hour: 8, delay_count: 15, total_seconds: 450, ...},
        %{hour: 17, delay_count: 12, total_seconds: 380, ...}
      ]
  """
  def delays_by_hour(line, opts \\ []) do
    since = Keyword.get(opts, :since, DateTime.add(DateTime.utc_now(), -7, :day))

    query = """
    SELECT
      EXTRACT(HOUR FROM started_at) as hour,
      COUNT(*) as delay_count,
      COALESCE(SUM(duration_seconds), 0) as total_seconds,
      COALESCE(AVG(duration_seconds), 0) as avg_seconds,
      SUM(CASE WHEN classification = 'blockage' THEN 1 ELSE 0 END) as blockage_count,
      SUM(CASE WHEN near_intersection THEN 1 ELSE 0 END) as intersection_delays
    FROM delay_events
    WHERE line = $1
      AND started_at >= $2
    GROUP BY EXTRACT(HOUR FROM started_at)
    ORDER BY total_seconds DESC
    """

    case Repo.query(query, [line, since]) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [hour, count, total, avg, blockages, intersection] ->
          %{
            hour: to_int(hour),
            delay_count: count,
            total_seconds: total || 0,
            avg_seconds: to_float(avg),
            blockage_count: blockages || 0,
            intersection_delays: intersection || 0
          }
        end)

      {:error, _} ->
        []
    end
  end

  @doc """
  Returns overall stats for a specific line.

  ## Options
  - `:since` - DateTime to filter from (default: last 7 days)
  """
  def summary(line, opts \\ []) do
    since = Keyword.get(opts, :since, DateTime.add(DateTime.utc_now(), -7, :day))

    query =
      from d in DelayEvent,
        where: d.line == ^line and d.started_at >= ^since,
        select: %{
          total_delays: count(d.id),
          total_seconds: sum(d.duration_seconds),
          avg_seconds: avg(d.duration_seconds),
          blockage_count:
            sum(fragment("CASE WHEN classification = 'blockage' THEN 1 ELSE 0 END")),
          intersection_delays: sum(fragment("CASE WHEN near_intersection THEN 1 ELSE 0 END"))
        }

    case Repo.one(query) do
      nil ->
        %{
          total_delays: 0,
          total_seconds: 0,
          avg_seconds: 0,
          blockage_count: 0,
          intersection_delays: 0
        }

      result ->
        %{
          result
          | avg_seconds: to_float(result.avg_seconds),
            total_seconds: result.total_seconds || 0
        }
    end
  end

  @doc """
  Returns top problematic intersections for a specific line.

  Shows which intersections cause the most delays for this line specifically.
  Clusters nearby delay points (within ~55m) to group them as one location.
  Includes both 'delay' and 'blockage' events near intersections.

  ## Options
  - `:since` - DateTime to filter from (default: last 7 days)
  - `:limit` - Max results (default: 5)
  """
  def hot_spots(line, opts \\ []) do
    since = Keyword.get(opts, :since, DateTime.add(DateTime.utc_now(), -7, :day))
    limit = Keyword.get(opts, :limit, 5)

    query = """
    WITH line_delays AS (
      SELECT
        ST_SetSRID(ST_MakePoint(d.lon, d.lat), 4326) as geom,
        d.duration_seconds,
        d.classification
      FROM delay_events d
      WHERE d.line = $1
        AND d.started_at >= $2
        AND d.near_intersection = true
    ),
    clustered AS (
      SELECT
        geom,
        duration_seconds,
        classification,
        ST_ClusterDBSCAN(geom::geometry, eps := 0.0005, minpoints := 1) OVER () as cluster_id
      FROM line_delays
    ),
    cluster_stats AS (
      SELECT
        cluster_id,
        ST_Centroid(ST_Collect(geom)) as centroid,
        COUNT(*) as event_count,
        SUM(CASE WHEN classification = 'delay' THEN 1 ELSE 0 END) as delay_count,
        SUM(CASE WHEN classification = 'blockage' THEN 1 ELSE 0 END) as blockage_count,
        COALESCE(SUM(duration_seconds), 0) as total_seconds,
        COALESCE(AVG(duration_seconds), 0) as avg_seconds
      FROM clustered
      GROUP BY cluster_id
    )
    SELECT
      ST_Y(cs.centroid) as lat,
      ST_X(cs.centroid) as lon,
      cs.event_count,
      cs.delay_count,
      cs.blockage_count,
      cs.total_seconds,
      cs.avg_seconds,
      COALESCE(
        (
          SELECT i.name
          FROM intersections i
          WHERE i.name IS NOT NULL AND i.name != ''
            AND ST_DWithin(i.geom::geography, cs.centroid::geography, 100)
          ORDER BY i.geom::geography <-> cs.centroid::geography
          LIMIT 1
        ),
        (
          SELECT s.name
          FROM stops s
          WHERE NOT s.is_terminal
          ORDER BY s.geom::geography <-> cs.centroid::geography
          LIMIT 1
        )
      ) as location_name,
      EXISTS (
        SELECT 1 FROM intersections i
        WHERE i.name IS NOT NULL AND i.name != ''
          AND ST_DWithin(i.geom::geography, cs.centroid::geography, 100)
      ) as is_intersection
    FROM cluster_stats cs
    ORDER BY cs.total_seconds DESC, cs.event_count DESC
    LIMIT $3
    """

    case Repo.query(query, [line, since, limit]) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [
                            lat,
                            lon,
                            event_count,
                            delay_count,
                            blockage_count,
                            total,
                            avg,
                            stop_name,
                            is_intersection
                          ] ->
          %{
            lat: lat,
            lon: lon,
            event_count: event_count,
            delay_count: delay_count,
            blockage_count: blockage_count,
            total_seconds: total || 0,
            avg_seconds: to_float(avg),
            location_name: stop_name,
            is_intersection: is_intersection
          }
        end)

      {:error, _} ->
        []
    end
  end

  @doc """
  Returns all lines that have recorded delays.

  Useful for building line selector dropdowns.
  """
  def lines_with_delays(opts \\ []) do
    since = Keyword.get(opts, :since, DateTime.add(DateTime.utc_now(), -7, :day))

    from(d in DelayEvent,
      where: d.started_at >= ^since,
      group_by: d.line,
      select: d.line,
      order_by: d.line
    )
    |> Repo.all()
    |> Enum.sort_by(&String.to_integer/1)
    |> Enum.map(&to_string/1)
  end
end
