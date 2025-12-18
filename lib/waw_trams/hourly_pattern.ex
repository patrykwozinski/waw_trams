defmodule WawTrams.HourlyPattern do
  @moduledoc """
  Cumulative hour × day-of-week statistics for heatmap visualization.

  This table has exactly 168 rows (7 days × 24 hours).
  Counters are incremented daily by the aggregation task.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias WawTrams.Repo

  schema "hourly_patterns" do
    # 1 (Monday) - 7 (Sunday)
    field :day_of_week, :integer
    # 0-23
    field :hour, :integer
    field :delay_count, :integer, default: 0
    field :blockage_count, :integer, default: 0
    field :total_seconds, :integer, default: 0

    timestamps()
  end

  @required_fields ~w(day_of_week hour)a
  @optional_fields ~w(delay_count blockage_count total_seconds)a

  def changeset(pattern, attrs) do
    pattern
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:day_of_week, 1..7)
    |> validate_inclusion(:hour, 0..23)
  end

  @doc """
  Returns all hourly patterns as a grid for heatmap rendering.
  Much faster than computing from raw events.
  """
  def heatmap_grid do
    patterns = Repo.all(__MODULE__)

    # Create lookup map
    lookup =
      Enum.reduce(patterns, %{}, fn p, acc ->
        Map.put(acc, {p.day_of_week, p.hour}, p)
      end)

    # Find max for color scaling
    max_count =
      patterns
      |> Enum.map(& &1.delay_count)
      |> Enum.max(fn -> 1 end)

    # Build grid: hours 5-23, days 1-7
    grid =
      for hour <- 5..23 do
        cells =
          for day <- 1..7 do
            case Map.get(lookup, {day, hour}) do
              nil ->
                %{day: day, hour: hour, count: 0, total: 0, intensity: 0}

              p ->
                %{
                  day: p.day_of_week,
                  hour: p.hour,
                  count: p.delay_count,
                  total: p.total_seconds,
                  intensity:
                    if(max_count > 0, do: Float.round(p.delay_count / max_count, 2), else: 0)
                }
            end
          end

        %{hour: hour, cells: cells}
      end

    total_delays = patterns |> Enum.map(& &1.delay_count) |> Enum.sum()

    %{grid: grid, max_count: max_count, total_delays: total_delays}
  end

  @doc """
  Returns raw heatmap data as a list of maps.
  """
  def heatmap_data do
    from(p in __MODULE__,
      where: p.delay_count > 0 or p.blockage_count > 0,
      select: %{
        day_of_week: p.day_of_week,
        hour: p.hour,
        delay_count: p.delay_count,
        blockage_count: p.blockage_count,
        total_seconds: p.total_seconds
      },
      order_by: [p.day_of_week, p.hour]
    )
    |> Repo.all()
  end

  @doc """
  Increments counters for a specific day/hour slot.
  Used by the aggregation task.
  """
  def increment!(day_of_week, hour, delay_count, blockage_count, total_seconds) do
    from(p in __MODULE__,
      where: p.day_of_week == ^day_of_week and p.hour == ^hour
    )
    |> Repo.update_all(
      inc: [
        delay_count: delay_count,
        blockage_count: blockage_count,
        total_seconds: total_seconds
      ],
      set: [updated_at: DateTime.utc_now()]
    )
  end

  @doc """
  Resets all counters to zero. Use with caution!
  """
  def reset_all! do
    from(p in __MODULE__)
    |> Repo.update_all(
      set: [
        delay_count: 0,
        blockage_count: 0,
        total_seconds: 0,
        updated_at: DateTime.utc_now()
      ]
    )
  end
end
