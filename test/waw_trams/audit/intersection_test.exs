defmodule WawTrams.Audit.IntersectionTest do
  use WawTrams.DataCase, async: true

  alias WawTrams.Audit.Intersection
  alias WawTrams.{DelayEvent, HourlyIntersectionStat}

  @intersection_lat 52.23
  @intersection_lon 21.01

  setup do
    # Create a stop for nearest_stop lookup
    {:ok, _} =
      Repo.query(
        "INSERT INTO stops (stop_id, name, geom, is_terminal, inserted_at, updated_at) VALUES ($1, $2, ST_SetSRID(ST_MakePoint($3, $4), 4326), $5, NOW(), NOW())",
        ["test_stop", "Test Intersection Stop", @intersection_lon, @intersection_lat, false]
      )

    :ok
  end

  # Helper to create aggregated data
  defp create_aggregated_stat(attrs) do
    default = %{
      date: Date.utc_today(),
      hour: DateTime.utc_now().hour,
      lat: Float.round(@intersection_lat, 4),
      lon: Float.round(@intersection_lon, 4),
      delay_count: 1,
      multi_cycle_count: 0,
      total_seconds: 60,
      cost_pln: 1.5,
      lines: ["19"]
    }

    HourlyIntersectionStat.upsert!(Map.merge(default, attrs))
  end

  describe "summary/3" do
    test "returns summary from aggregated data" do
      # Create aggregated data
      create_aggregated_stat(%{delay_count: 3, total_seconds: 180, cost_pln: 4.5})

      result = Intersection.summary(@intersection_lat, @intersection_lon, since: DateTime.add(DateTime.utc_now(), -1, :day))

      assert result.delay_count == 3
      assert result.total_seconds == 180
      assert result.cost.total == 4.5
    end

    test "combines aggregated with current hour raw events" do
      now = DateTime.utc_now()

      # Create aggregated data from yesterday
      create_aggregated_stat(%{
        date: Date.add(Date.utc_today(), -1),
        delay_count: 2,
        total_seconds: 120,
        cost_pln: 3.0
      })

      # Create a current hour raw event at the same location
      {:ok, event} =
        DelayEvent.create(%{
          vehicle_id: "V/19/1",
          line: "19",
          lat: @intersection_lat,
          lon: @intersection_lon,
          started_at: now,
          classification: "delay",
          near_intersection: true
        })

      DelayEvent.resolve(event)

      result = Intersection.summary(@intersection_lat, @intersection_lon, since: DateTime.add(now, -2, :day))

      # Should have aggregated (2) + current hour (1) = 3
      assert result.delay_count == 3
    end

    test "returns zeros for intersection with no delays" do
      result = Intersection.summary(0.0, 0.0)

      assert result.delay_count == 0
      assert result.total_seconds == 0
      assert result.cost.total == 0
    end

    test "calculates multi_cycle percentage" do
      # 2 delays, 1 multi-cycle = 50%
      create_aggregated_stat(%{delay_count: 2, multi_cycle_count: 1})

      result = Intersection.summary(@intersection_lat, @intersection_lon, since: DateTime.add(DateTime.utc_now(), -1, :day))

      assert result.multi_cycle_count == 1
      assert result.multi_cycle_pct == 50.0
    end
  end

  describe "heatmap/3" do
    test "returns grid structure from aggregated data" do
      # Create aggregated data for different hours
      create_aggregated_stat(%{hour: 8, delay_count: 2})
      create_aggregated_stat(%{hour: 17, delay_count: 3})

      result = Intersection.heatmap(@intersection_lat, @intersection_lon, since: DateTime.add(DateTime.utc_now(), -1, :day))

      assert Map.has_key?(result, :grid)
      assert Map.has_key?(result, :max_count)
      assert Map.has_key?(result, :total_delays)

      # Grid should have hours 5-23 (19 rows)
      assert length(result.grid) == 19

      # Total should be sum of aggregated data
      assert result.total_delays == 5
    end

    test "returns empty grid for no delays" do
      result = Intersection.heatmap(0.0, 0.0)

      assert result.total_delays == 0
      assert result.max_count == 1
    end
  end

  describe "recent_delays/3" do
    test "returns recent delays at intersection" do
      now = DateTime.utc_now()

      {:ok, event} =
        DelayEvent.create(%{
          vehicle_id: "V/19/1",
          line: "19",
          lat: @intersection_lat,
          lon: @intersection_lon,
          started_at: now,
          classification: "delay"
        })

      DelayEvent.resolve(event)

      result = Intersection.recent_delays(@intersection_lat, @intersection_lon, since: DateTime.add(now, -1, :hour))

      assert length(result) == 1
      assert hd(result).line == "19"
    end

    test "respects limit" do
      now = DateTime.utc_now()

      for i <- 1..5 do
        {:ok, event} =
          DelayEvent.create(%{
            vehicle_id: "V/19/#{i}",
            line: "19",
            lat: @intersection_lat,
            lon: @intersection_lon,
            started_at: DateTime.add(now, -i, :second),
            classification: "delay"
          })

        DelayEvent.resolve(event)
      end

      result = Intersection.recent_delays(@intersection_lat, @intersection_lon, since: DateTime.add(now, -1, :hour), limit: 3)

      assert length(result) == 3
    end
  end
end
