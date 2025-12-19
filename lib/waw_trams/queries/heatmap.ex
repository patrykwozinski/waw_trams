defmodule WawTrams.Queries.Heatmap do
  @moduledoc """
  Functions for generating heatmap visualization data.

  Provides delay counts grouped by hour and day of week for
  identifying temporal patterns in tram delays.
  """

  alias WawTrams.Repo

  # Helper to safely convert Decimal/nil to integer
  defp to_int(nil), do: 0
  defp to_int(%Decimal{} = d), do: Decimal.to_integer(d)
  defp to_int(n) when is_number(n), do: trunc(n)

  @doc """
  Returns delay counts grouped by hour of day AND day of week.

  Perfect for heatmap visualization showing when delays peak.

  ## Options
  - `:since` - DateTime to filter from (default: last 7 days)
  - `:classification` - Filter by "delay" or "blockage" (default: all)

  ## Returns

  List of maps with:
  - `day_of_week` - 1 (Monday) to 7 (Sunday)
  - `hour` - 0 to 23
  - `delay_count` - Number of delays
  - `total_seconds` - Total delay time
  """
  def data(opts \\ []) do
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

  Hours 5-23 (typical tram operation), Days Mon-Sun.

  ## Returns

  Map with:
  - `grid` - List of hour rows, each with `cells` for each day
  - `max_count` - Maximum delay count (for color scaling)
  - `total_delays` - Sum of all delays in the period

  ## Example

      %{
        grid: [
          %{hour: 5, cells: [%{day: 1, count: 2, intensity: 0.1}, ...]},
          %{hour: 6, cells: [%{day: 1, count: 15, intensity: 0.75}, ...]},
          ...
        ],
        max_count: 20,
        total_delays: 450
      }
  """
  def grid(opts \\ []) do
    raw_data = data(opts)

    # Create a lookup map
    lookup =
      Enum.reduce(raw_data, %{}, fn %{day_of_week: dow, hour: h} = row, acc ->
        Map.put(acc, {dow, h}, row)
      end)

    # Find max for color scaling
    max_count = raw_data |> Enum.map(& &1.delay_count) |> Enum.max(fn -> 1 end)

    # Build grid: hours 5-23 (typical operation), days 1-7
    grid_rows =
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
      grid: grid_rows,
      max_count: max_count,
      total_delays: Enum.sum(Enum.map(raw_data, & &1.delay_count))
    }
  end
end
