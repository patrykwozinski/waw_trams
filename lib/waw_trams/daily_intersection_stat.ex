defmodule WawTrams.DailyIntersectionStat do
  @moduledoc """
  Daily aggregated statistics per intersection location.

  Locations are grouped by rounding coordinates to 4 decimal places (~11m precision).
  This allows efficient historical queries without expensive spatial clustering.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias WawTrams.Repo

  schema "daily_intersection_stats" do
    field :date, :date
    field :lat, :float
    field :lon, :float
    field :location_name, :string
    field :delay_count, :integer, default: 0
    field :blockage_count, :integer, default: 0
    field :total_seconds, :integer, default: 0
    field :affected_lines, {:array, :string}, default: []

    timestamps()
  end

  @required_fields ~w(date lat lon)a
  @optional_fields ~w(location_name delay_count blockage_count total_seconds affected_lines)a

  def changeset(stat, attrs) do
    stat
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
  end

  @doc """
  Returns hot spots for a date range using aggregated data.
  Much faster than querying raw delay_events for long time ranges.
  """
  def hot_spots(opts \\ []) do
    since = Keyword.get(opts, :since, Date.add(Date.utc_today(), -30))
    limit = Keyword.get(opts, :limit, 20)

    from(s in __MODULE__,
      where: s.date >= ^since,
      group_by: [s.lat, s.lon, s.location_name],
      select: %{
        lat: s.lat,
        lon: s.lon,
        location_name: s.location_name,
        delay_count: sum(s.delay_count),
        blockage_count: sum(s.blockage_count),
        total_seconds: sum(s.total_seconds),
        days_count: count(s.id)
      },
      order_by: [desc: sum(s.delay_count), desc: sum(s.total_seconds)],
      limit: ^limit
    )
    |> Repo.all()
    |> Enum.map(fn row ->
      # Collect affected lines across all days
      lines = get_affected_lines(row.lat, row.lon, since)

      %{
        lat: row.lat,
        lon: row.lon,
        location_name: row.location_name,
        delay_count: row.delay_count,
        blockage_count: row.blockage_count,
        total_seconds: row.total_seconds,
        affected_lines: lines,
        avg_delay_seconds: safe_div(row.total_seconds, row.delay_count + row.blockage_count)
      }
    end)
  end

  defp get_affected_lines(lat, lon, since) do
    from(s in __MODULE__,
      where: s.date >= ^since and s.lat == ^lat and s.lon == ^lon,
      select: s.affected_lines
    )
    |> Repo.all()
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  Returns summary stats for a date range.
  """
  def summary(opts \\ []) do
    since = Keyword.get(opts, :since, Date.add(Date.utc_today(), -30))

    from(s in __MODULE__,
      where: s.date >= ^since,
      select: %{
        intersection_count: count(fragment("DISTINCT (?, ?)", s.lat, s.lon)),
        total_delays: sum(s.delay_count),
        total_blockages: sum(s.blockage_count),
        total_seconds: sum(s.total_seconds)
      }
    )
    |> Repo.one()
    |> then(fn
      nil -> %{intersection_count: 0, total_delays: 0, total_blockages: 0, total_seconds: 0}
      result -> %{result | total_seconds: result.total_seconds || 0}
    end)
  end

  @doc """
  Upserts a daily stat record.
  """
  def upsert!(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
    |> Repo.insert!(
      on_conflict:
        {:replace, [:delay_count, :blockage_count, :total_seconds, :affected_lines, :updated_at]},
      conflict_target: [:date, :lat, :lon]
    )
  end

  defp safe_div(_, 0), do: 0.0
  defp safe_div(nil, _), do: 0.0
  defp safe_div(num, denom), do: Float.round(num / denom, 1)
end
