defmodule WawTrams.DelayEvent do
  @moduledoc """
  Schema for delay events detected by TramWorkers.

  Only actionable delays are persisted:
  - `blockage`: >180s at a stop (potential incident, not normal boarding)
  - `delay`: >30s NOT at a stop (traffic/signal issue - the gold!)

  Normal dwell times (<180s at stops) and brief stops (<30s) are not stored.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias WawTrams.Repo

  schema "delay_events" do
    field :vehicle_id, :string
    field :line, :string
    field :trip_id, :string

    # Location
    field :lat, :float
    field :lon, :float

    # Timing
    field :started_at, :utc_datetime_usec
    field :resolved_at, :utc_datetime_usec
    field :duration_seconds, :integer

    # Classification
    field :classification, :string
    field :at_stop, :boolean, default: false
    field :near_intersection, :boolean, default: false
    # True if delay > 120s (Warsaw signal cycle) = priority system failure
    field :multi_cycle, :boolean, default: false

    timestamps()
  end

  # Warsaw signal cycle length in seconds
  @signal_cycle_seconds 120

  @required_fields ~w(vehicle_id lat lon started_at classification)a
  @optional_fields ~w(line trip_id resolved_at duration_seconds at_stop near_intersection multi_cycle)a

  def changeset(delay_event, attrs) do
    delay_event
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:classification, ~w(blockage delay))
  end

  @doc """
  Creates a new delay event when a delay is first detected.
  """
  def create(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Gets a delay event by ID.
  """
  def get(id), do: Repo.get(__MODULE__, id)

  @doc """
  Finds an unresolved delay event for a vehicle.
  """
  def find_unresolved(vehicle_id) do
    __MODULE__
    |> where([d], d.vehicle_id == ^vehicle_id and is_nil(d.resolved_at))
    |> order_by([d], desc: d.started_at)
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Resolves a delay event when the tram starts moving again.

  Sets `multi_cycle: true` if:
  - Duration exceeds Warsaw signal cycle (120s), AND
  - Event is near an intersection (not just at a stop)

  This flags signal priority failures specifically, not long boarding times.
  """
  def resolve(%__MODULE__{} = event) do
    now = DateTime.utc_now()
    duration = DateTime.diff(now, event.started_at, :second)

    # Multi-cycle only applies to intersection delays, not stop blockages
    multi_cycle =
      duration > @signal_cycle_seconds and (event.near_intersection or not event.at_stop)

    event
    |> changeset(%{resolved_at: now, duration_seconds: duration, multi_cycle: multi_cycle})
    |> Repo.update()
  end

  @doc """
  Deletes all orphaned delay events (unresolved delays from previous server runs).

  Called on application startup to clean up hanging delays that would never
  be resolved because their TramWorker processes no longer exist.

  We delete rather than resolve because:
  - We don't know when the tram actually moved
  - Server downtime would create artificially long durations
  - This would skew analytics (avg delay, total time lost)
  """
  def cleanup_orphaned do
    {count, _} =
      from(d in __MODULE__, where: is_nil(d.resolved_at))
      |> Repo.delete_all()

    if count > 0 do
      require Logger
      Logger.info("[STARTUP] Deleted #{count} orphaned delay events from previous run")
    end

    {:ok, count}
  end

  @doc """
  Returns recent delay events for dashboard/visualization.
  """
  def recent(limit \\ 100) do
    __MODULE__
    |> order_by([d], desc: d.started_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Returns currently active (unresolved) delays.
  """
  def active do
    __MODULE__
    |> where([d], is_nil(d.resolved_at))
    |> order_by([d], desc: d.started_at)
    |> Repo.all()
  end

  @doc """
  Counts currently active (unresolved) delays.
  Used by Telemetry for metrics.
  """
  def count_active do
    __MODULE__
    |> where([d], is_nil(d.resolved_at))
    |> Repo.aggregate(:count, :id)
  end

  @doc """
  Counts delays started today (UTC).
  Used by Telemetry for metrics.
  """
  def count_today do
    today_start = DateTime.utc_now() |> DateTime.to_date() |> DateTime.new!(~T[00:00:00])

    __MODULE__
    |> where([d], d.started_at >= ^today_start)
    |> Repo.aggregate(:count, :id)
  end

  @doc """
  Returns delay statistics for a time period.
  """
  def stats(since \\ DateTime.add(DateTime.utc_now(), -24, :hour)) do
    query =
      from d in __MODULE__,
        where: d.started_at >= ^since,
        group_by: d.classification,
        select: {d.classification, count(d.id), avg(d.duration_seconds)}

    query
    |> Repo.all()
    |> Enum.map(fn {classification, count, avg_duration} ->
      %{
        classification: classification,
        count: count,
        avg_duration_seconds: avg_duration && Decimal.to_float(avg_duration)
      }
    end)
  end

  @doc """
  Returns count of multi-cycle delays (priority failures) in a time period.

  Multi-cycle means delay > 120s (Warsaw signal cycle), indicating the
  tram missed multiple green phases due to broken priority.
  """
  def multi_cycle_count(since \\ DateTime.add(DateTime.utc_now(), -24, :hour)) do
    from(d in __MODULE__,
      where: d.started_at >= ^since and d.multi_cycle == true,
      select: count(d.id)
    )
    |> Repo.one()
  end

  # --- Hot Spot Analysis ---

  @doc """
  Returns top problematic intersections ranked by delay count.

  Clusters nearby intersection nodes (within 30m) to treat them as one
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

    # Cluster intersection nodes within 30m, then aggregate delays per cluster
    # Also find the nearest stop name for human-readable location
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
  Returns delays at a specific intersection cluster (by cluster_id from hot_spots).
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
  Returns tram lines ranked by intersection delay impact.
  """
  def impacted_lines(opts \\ []) do
    since = Keyword.get(opts, :since, DateTime.add(DateTime.utc_now(), -24, :hour))
    limit = Keyword.get(opts, :limit, 10)

    query =
      from d in __MODULE__,
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

  @doc """
  Returns delays grouped by hour of day for a specific line.
  Useful for identifying worst commute times.
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
  """
  def line_summary(line, opts \\ []) do
    since = Keyword.get(opts, :since, DateTime.add(DateTime.utc_now(), -7, :day))

    query =
      from d in __MODULE__,
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
  """
  def line_hot_spots(line, opts \\ []) do
    since = Keyword.get(opts, :since, DateTime.add(DateTime.utc_now(), -7, :day))
    limit = Keyword.get(opts, :limit, 5)

    # Cluster delay points within ~55m (0.0005 degrees) before aggregating
    # Include both delays and blockages near intersections
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
      (
        SELECT s.name
        FROM stops s
        WHERE NOT s.is_terminal
        ORDER BY s.geom::geography <-> cs.centroid::geography
        LIMIT 1
      ) as nearest_stop
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
                            stop_name
                          ] ->
          %{
            lat: lat,
            lon: lon,
            event_count: event_count,
            delay_count: delay_count,
            blockage_count: blockage_count,
            total_seconds: total || 0,
            avg_seconds: to_float(avg),
            nearest_stop: stop_name
          }
        end)

      {:error, _} ->
        []
    end
  end

  @doc """
  Returns all lines that have recorded delays.
  """
  def lines_with_delays(opts \\ []) do
    since = Keyword.get(opts, :since, DateTime.add(DateTime.utc_now(), -7, :day))

    from(d in __MODULE__,
      where: d.started_at >= ^since,
      group_by: d.line,
      select: d.line,
      order_by: d.line
    )
    |> Repo.all()
    |> Enum.sort_by(&String.to_integer/1)
    |> Enum.map(&to_string/1)
  end

  @doc """
  Returns delay counts grouped by hour of day AND day of week.
  Perfect for heatmap visualization showing when delays peak.

  Returns a map like: %{{day_of_week, hour} => count}
  where day_of_week is 1 (Monday) to 7 (Sunday)
  """
  def heatmap_data(opts \\ []) do
    since = Keyword.get(opts, :since, DateTime.add(DateTime.utc_now(), -7, :day))
    classification = Keyword.get(opts, :classification, nil)

    query = """
    SELECT
      EXTRACT(ISODOW FROM started_at) as day_of_week,
      EXTRACT(HOUR FROM started_at) as hour,
      COUNT(*) as delay_count,
      COALESCE(SUM(duration_seconds), 0) as total_seconds
    FROM delay_events
    WHERE started_at >= $1
      #{if classification, do: "AND classification = '#{classification}'", else: ""}
    GROUP BY
      EXTRACT(ISODOW FROM started_at),
      EXTRACT(HOUR FROM started_at)
    ORDER BY day_of_week, hour
    """

    case Repo.query(query, [since]) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [dow, hour, count, total] ->
          %{
            day_of_week: to_int(dow),
            hour: to_int(hour),
            delay_count: count,
            total_seconds: total || 0
          }
        end)

      {:error, _} ->
        []
    end
  end

  @doc """
  Returns heatmap data as a structured grid for easy rendering.
  Hours 5-24 (typical tram operation), Days Mon-Sun.
  """
  def heatmap_grid(opts \\ []) do
    data = heatmap_data(opts)

    # Create a lookup map
    lookup =
      Enum.reduce(data, %{}, fn %{day_of_week: dow, hour: h} = row, acc ->
        Map.put(acc, {dow, h}, row)
      end)

    # Find max for color scaling
    max_count = data |> Enum.map(& &1.delay_count) |> Enum.max(fn -> 1 end)

    # Build grid: hours 5-23 (typical operation), days 1-7
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

    %{grid: grid, max_count: max_count, total_delays: Enum.sum(Enum.map(data, & &1.delay_count))}
  end

  # Helper to safely convert Decimal/nil to float
  defp to_float(nil), do: 0.0
  defp to_float(%Decimal{} = d), do: Decimal.to_float(d) |> Float.round(1)
  defp to_float(n) when is_number(n), do: Float.round(n * 1.0, 1)

  # Helper to safely convert Decimal/nil to integer
  defp to_int(nil), do: 0
  defp to_int(%Decimal{} = d), do: Decimal.to_integer(d)
  defp to_int(n) when is_number(n), do: trunc(n)
end
