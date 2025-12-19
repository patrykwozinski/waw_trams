defmodule WawTrams.Queries.HeatmapTest do
  use WawTrams.DataCase, async: true

  alias WawTrams.Queries.Heatmap
  alias WawTrams.DelayEvent

  describe "data/1" do
    test "groups by day of week and hour" do
      now = DateTime.utc_now()

      {:ok, event} =
        DelayEvent.create(%{
          vehicle_id: "V/19/1",
          line: "19",
          lat: 52.23,
          lon: 21.01,
          started_at: DateTime.add(now, -60, :second),
          classification: "delay"
        })

      DelayEvent.resolve(event)

      result = Heatmap.data(since: DateTime.add(now, -1, :hour))

      assert length(result) >= 1
      first = hd(result)
      assert Map.has_key?(first, :day_of_week)
      assert Map.has_key?(first, :hour)
      assert Map.has_key?(first, :delay_count)
      assert Map.has_key?(first, :total_seconds)
    end

    test "filters by classification" do
      now = DateTime.utc_now()

      {:ok, delay} =
        DelayEvent.create(%{
          vehicle_id: "V/19/1",
          line: "19",
          lat: 52.23,
          lon: 21.01,
          started_at: DateTime.add(now, -60, :second),
          classification: "delay"
        })

      {:ok, blockage} =
        DelayEvent.create(%{
          vehicle_id: "V/19/2",
          line: "19",
          lat: 52.23,
          lon: 21.01,
          started_at: DateTime.add(now, -120, :second),
          classification: "blockage"
        })

      DelayEvent.resolve(delay)
      DelayEvent.resolve(blockage)

      # Filter to only delays
      result = Heatmap.data(since: DateTime.add(now, -1, :hour), classification: "delay")

      total_count = Enum.reduce(result, 0, fn row, acc -> acc + row.delay_count end)
      assert total_count == 1
    end

    test "returns empty list when no data" do
      result = Heatmap.data()
      assert result == []
    end
  end

  describe "grid/1" do
    test "returns structured grid with all hours 5-23" do
      now = DateTime.utc_now()

      {:ok, event} =
        DelayEvent.create(%{
          vehicle_id: "V/19/1",
          line: "19",
          lat: 52.23,
          lon: 21.01,
          started_at: DateTime.add(now, -60, :second),
          classification: "delay"
        })

      DelayEvent.resolve(event)

      result = Heatmap.grid(since: DateTime.add(now, -1, :hour))

      assert Map.has_key?(result, :grid)
      assert Map.has_key?(result, :max_count)
      assert Map.has_key?(result, :total_delays)

      # Grid should have hours 5-23 (19 rows)
      assert length(result.grid) == 19

      # Each row should have 7 day cells
      first_row = hd(result.grid)
      assert length(first_row.cells) == 7
    end

    test "calculates intensity relative to max" do
      now = DateTime.utc_now()

      # Create multiple delays
      for i <- 1..5 do
        {:ok, event} =
          DelayEvent.create(%{
            vehicle_id: "V/19/#{i}",
            line: "19",
            lat: 52.23,
            lon: 21.01,
            started_at: DateTime.add(now, -60 * i, :second),
            classification: "delay"
          })

        DelayEvent.resolve(event)
      end

      result = Heatmap.grid(since: DateTime.add(now, -1, :hour))

      # Max count should be >= 1
      assert result.max_count >= 1

      # Total delays should match our created events
      assert result.total_delays == 5
    end

    test "handles empty data gracefully" do
      result = Heatmap.grid()

      assert result.max_count == 1
      assert result.total_delays == 0
      assert length(result.grid) == 19
    end
  end
end
