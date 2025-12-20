defmodule WawTrams.HourlyIntersectionStat do
  @moduledoc """
  Hourly aggregated statistics per intersection cluster.

  Pre-calculates cost using the hour of day for accurate passenger estimates.
  Used by Audit Dashboard for fast queries.
  """

  use Ecto.Schema
  import Ecto.Query

  alias WawTrams.Repo

  @primary_key {:id, :id, autogenerate: true}
  schema "hourly_intersection_stats" do
    field :date, :date
    field :hour, :integer

    # Cluster centroid (rounded to 4 decimals)
    field :lat, :float
    field :lon, :float

    # Stats
    field :delay_count, :integer, default: 0
    field :multi_cycle_count, :integer, default: 0
    field :total_seconds, :integer, default: 0

    # Pre-calculated cost
    field :cost_pln, :float, default: 0.0

    # Affected lines
    field :lines, {:array, :string}, default: []

    timestamps()
  end

  @doc """
  Upserts hourly intersection stats.
  """
  def upsert!(attrs) do
    %__MODULE__{}
    |> Ecto.Changeset.cast(attrs, [
      :date,
      :hour,
      :lat,
      :lon,
      :delay_count,
      :multi_cycle_count,
      :total_seconds,
      :cost_pln,
      :lines
    ])
    |> Repo.insert!(
      on_conflict:
        {:replace,
         [:delay_count, :multi_cycle_count, :total_seconds, :cost_pln, :lines, :updated_at]},
      conflict_target: [:date, :hour, :lat, :lon]
    )
  end

  @doc """
  Returns aggregated stats for a date range.
  Used by Summary.stats/1.

  Accepts either a Date or DateTime for the :since option.
  When a DateTime is provided, it properly filters by (date, hour) to handle partial days.
  """
  def aggregate_stats(opts \\ []) do
    since = Keyword.get(opts, :since, Date.add(Date.utc_today(), -7))
    line = Keyword.get(opts, :line, nil)

    # Handle both Date and DateTime inputs
    {since_date, since_hour} =
      case since do
        %DateTime{} = dt -> {DateTime.to_date(dt), dt.hour}
        %Date{} = d -> {d, 0}
      end

    # Build query that handles partial days correctly
    # Include: full days after since_date, OR since_date with hour >= since_hour
    query =
      from(s in __MODULE__,
        where: s.date > ^since_date or (s.date == ^since_date and s.hour >= ^since_hour)
      )

    query =
      if line do
        from(s in query, where: ^line in s.lines)
      else
        query
      end

    from(s in query,
      select: %{
        total_delays: sum(s.delay_count),
        multi_cycle_count: sum(s.multi_cycle_count),
        total_seconds: sum(s.total_seconds),
        total_cost: sum(s.cost_pln)
      }
    )
    |> Repo.one() || %{total_delays: 0, multi_cycle_count: 0, total_seconds: 0, total_cost: 0}
  end

  @doc """
  Returns leaderboard of worst intersections by cost.
  Used by Summary.leaderboard/1.
  """
  def leaderboard(opts \\ []) do
    since_date = Keyword.get(opts, :since, Date.add(Date.utc_today(), -7))
    limit = Keyword.get(opts, :limit, 10)
    line = Keyword.get(opts, :line, nil)

    base_query = from(s in __MODULE__, where: s.date >= ^since_date)

    base_query =
      if line do
        from(s in base_query, where: ^line in s.lines)
      else
        base_query
      end

    # Group by location (rounded lat/lon) and aggregate
    from(s in base_query,
      group_by: [s.lat, s.lon],
      select: %{
        lat: s.lat,
        lon: s.lon,
        delay_count: sum(s.delay_count),
        multi_cycle_count: sum(s.multi_cycle_count),
        total_seconds: sum(s.total_seconds),
        cost_pln: sum(s.cost_pln),
        lines: fragment("array_agg(DISTINCT unnest) FROM unnest(?)", s.lines)
      },
      order_by: [desc: sum(s.cost_pln)],
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc """
  Returns stats for a specific intersection location.
  Uses spatial proximity (~110m) to match cluster centroids.
  Used by Intersection.summary/3.
  """
  def intersection_stats(lat, lon, opts \\ []) do
    since_date = Keyword.get(opts, :since, Date.add(Date.utc_today(), -7))

    # Use spatial proximity to match any points within ~110m of the centroid
    # This is needed because leaderboard returns cluster centroids
    query = """
    SELECT
      COALESCE(SUM(delay_count), 0) as delay_count,
      COALESCE(SUM(multi_cycle_count), 0) as multi_cycle_count,
      COALESCE(SUM(total_seconds), 0) as total_seconds,
      COALESCE(SUM(cost_pln), 0) as cost_pln
    FROM hourly_intersection_stats
    WHERE date >= $1
      AND ST_DWithin(
        ST_SetSRID(ST_MakePoint(lon, lat), 4326)::geography,
        ST_SetSRID(ST_MakePoint($2, $3), 4326)::geography,
        110
      )
    """

    case Repo.query(query, [since_date, lon, lat]) do
      {:ok, %{rows: [[delay_count, multi_cycle_count, total_seconds, cost_pln]]}} ->
        %{
          delay_count: delay_count || 0,
          multi_cycle_count: multi_cycle_count || 0,
          total_seconds: total_seconds || 0,
          cost_pln: cost_pln || 0.0
        }

      _ ->
        %{delay_count: 0, multi_cycle_count: 0, total_seconds: 0, cost_pln: 0}
    end
  end

  @doc """
  Returns hour×day heatmap for a specific intersection.
  Uses spatial proximity (~110m) to match cluster centroids.
  """
  def intersection_heatmap(lat, lon, opts \\ []) do
    since_date = Keyword.get(opts, :since, Date.add(Date.utc_today(), -7))

    query = """
    SELECT
      EXTRACT(ISODOW FROM date)::integer as day_of_week,
      hour,
      SUM(delay_count) as delay_count,
      SUM(total_seconds) as total_seconds
    FROM hourly_intersection_stats
    WHERE date >= $1
      AND ST_DWithin(
        ST_SetSRID(ST_MakePoint(lon, lat), 4326)::geography,
        ST_SetSRID(ST_MakePoint($2, $3), 4326)::geography,
        110
      )
    GROUP BY EXTRACT(ISODOW FROM date), hour
    ORDER BY day_of_week, hour
    """

    case Repo.query(query, [since_date, lon, lat]) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [dow, hour, count, total] ->
          %{
            day_of_week: dow,
            hour: hour,
            delay_count: count || 0,
            total_seconds: total || 0
          }
        end)

      _ ->
        []
    end
  end

  @doc """
  Counts unique intersection clusters in a date range.
  Accepts either a Date or DateTime for the :since option.
  """
  def count_intersections(opts \\ []) do
    since = Keyword.get(opts, :since, Date.add(Date.utc_today(), -7))
    line = Keyword.get(opts, :line, nil)

    # Handle both Date and DateTime inputs
    {since_date, since_hour} =
      case since do
        %DateTime{} = dt -> {DateTime.to_date(dt), dt.hour}
        %Date{} = d -> {d, 0}
      end

    query =
      from(s in __MODULE__,
        where: s.date > ^since_date or (s.date == ^since_date and s.hour >= ^since_hour)
      )

    query =
      if line do
        from(s in query, where: ^line in s.lines)
      else
        query
      end

    from(s in query,
      select: count(fragment("DISTINCT (?, ?)", s.lat, s.lon))
    )
    |> Repo.one() || 0
  end
end
