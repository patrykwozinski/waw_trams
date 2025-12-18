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

    timestamps()
  end

  @required_fields ~w(vehicle_id lat lon started_at classification)a
  @optional_fields ~w(line trip_id resolved_at duration_seconds at_stop near_intersection)a

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
  """
  def resolve(%__MODULE__{} = event) do
    now = DateTime.utc_now()
    duration = DateTime.diff(now, event.started_at, :second)

    event
    |> changeset(%{resolved_at: now, duration_seconds: duration})
    |> Repo.update()
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
    query = """
    WITH clustered_intersections AS (
      SELECT
        osm_id,
        geom,
        ST_ClusterDBSCAN(geom::geometry, eps := 0.0003, minpoints := 1) OVER () as cluster_id
      FROM intersections
    ),
    cluster_centroids AS (
      SELECT
        cluster_id,
        ST_Centroid(ST_Collect(geom)) as centroid,
        array_agg(osm_id) as osm_ids
      FROM clustered_intersections
      GROUP BY cluster_id
    )
    SELECT
      c.cluster_id,
      c.osm_ids,
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
    ORDER BY delay_count DESC, total_delay_seconds DESC
    LIMIT $3
    """

    case Repo.query(query, [since, classification, limit]) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [cluster_id, osm_ids, lat, lon, count, total, avg, lines] ->
          %{
            cluster_id: cluster_id,
            osm_ids: osm_ids,
            lat: lat,
            lon: lon,
            delay_count: count,
            total_delay_seconds: total,
            avg_delay_seconds: to_float(avg),
            affected_lines: Enum.reject(lines, &is_nil/1) |> Enum.sort()
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
        ST_ClusterDBSCAN(geom::geometry, eps := 0.0003, minpoints := 1) OVER () as cluster_id
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
        Enum.map(rows, fn [id, vehicle_id, line, lat, lon, started_at, resolved_at, duration, classification] ->
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
        ST_ClusterDBSCAN(geom::geometry, eps := 0.0003, minpoints := 1) OVER () as cluster_id
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

  # Helper to safely convert Decimal/nil to float
  defp to_float(nil), do: 0.0
  defp to_float(%Decimal{} = d), do: Decimal.to_float(d) |> Float.round(1)
  defp to_float(n) when is_number(n), do: Float.round(n * 1.0, 1)
end
