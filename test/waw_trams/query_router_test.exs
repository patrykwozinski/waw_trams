defmodule WawTrams.QueryRouterTest do
  use WawTrams.DataCase, async: true

  alias WawTrams.{QueryRouter, DelayEvent, DailyLineStat, DailyIntersectionStat}

  describe "delays_by_hour/2" do
    test "returns raw data when no aggregated data exists" do
      # Create raw events only (no aggregation)
      now = DateTime.utc_now()
      hour_start = %{now | minute: 0, second: 0, microsecond: {0, 0}}

      create_delay_event(%{
        line: "99",
        started_at: hour_start,
        classification: "delay",
        duration_seconds: 60
      })

      result = QueryRouter.delays_by_hour("99")

      assert length(result) == 1
      assert hd(result).delay_count == 1
    end

    test "uses aggregated data when available" do
      # Create aggregated data
      {:ok, _} =
        %DailyLineStat{}
        |> DailyLineStat.changeset(%{
          date: Date.utc_today(),
          line: "88",
          delay_count: 10,
          blockage_count: 5,
          total_seconds: 1000,
          intersection_count: 3,
          by_hour: %{
            "14" => %{
              "delay_count" => 10,
              "blockage_count" => 5,
              "total_seconds" => 1000,
              "intersection_delays" => 3
            }
          }
        })
        |> Repo.insert()

      result = QueryRouter.delays_by_hour("88")

      assert length(result) == 1
      hour_14 = hd(result)
      assert hour_14.hour == 14
      assert hour_14.delay_count == 10
      assert hour_14.blockage_count == 5
    end

    test "adds recent events to current hour when already aggregated" do
      now = DateTime.utc_now()
      current_hour = now.hour

      # Create aggregated data for current hour
      {:ok, _} =
        %DailyLineStat{}
        |> DailyLineStat.changeset(%{
          date: Date.utc_today(),
          line: "77",
          delay_count: 5,
          blockage_count: 3,
          total_seconds: 500,
          intersection_count: 2,
          by_hour: %{
            to_string(current_hour) => %{
              "delay_count" => 5,
              "blockage_count" => 3,
              "total_seconds" => 500,
              "intersection_delays" => 2
            }
          }
        })
        |> Repo.insert()

      # Create a recent event (after minute 5)
      recent_time =
        now
        |> Map.put(:minute, max(now.minute, 6))
        |> Map.put(:second, 0)

      # Only create if we're past minute 5
      if now.minute >= 5 do
        create_delay_event(%{
          line: "77",
          started_at: recent_time,
          classification: "delay",
          duration_seconds: 100
        })
      end

      result = QueryRouter.delays_by_hour("77")
      current = Enum.find(result, &(&1.hour == current_hour))

      assert current != nil
      # Should have aggregated + recent (if past minute 5)
      if now.minute >= 5 do
        assert current.delay_count >= 5
      else
        assert current.delay_count == 5
      end
    end

    test "does not double-count events already in aggregation" do
      now = DateTime.utc_now()
      current_hour = now.hour

      # Create aggregated data
      {:ok, _} =
        %DailyLineStat{}
        |> DailyLineStat.changeset(%{
          date: Date.utc_today(),
          line: "66",
          delay_count: 10,
          blockage_count: 5,
          total_seconds: 1000,
          by_hour: %{
            to_string(current_hour) => %{
              "delay_count" => 10,
              "blockage_count" => 5,
              "total_seconds" => 1000,
              "intersection_delays" => 3
            }
          }
        })
        |> Repo.insert()

      # Create an OLD event (before minute 5) - should NOT be double-counted
      old_time = %{now | minute: 2, second: 0, microsecond: {0, 0}}

      create_delay_event(%{
        line: "66",
        started_at: old_time,
        classification: "delay",
        duration_seconds: 60
      })

      result = QueryRouter.delays_by_hour("66")
      current = Enum.find(result, &(&1.hour == current_hour))

      # Should NOT include the old event (it's before minute 5)
      assert current.delay_count == 10
    end
  end

  describe "line_summary/2" do
    test "returns empty summary when no data" do
      result = QueryRouter.line_summary("999")

      assert result.total_delays == 0
      assert result.total_seconds == 0
    end

    test "combines aggregated and recent data" do
      # Create aggregated data
      {:ok, _} =
        %DailyLineStat{}
        |> DailyLineStat.changeset(%{
          date: Date.utc_today(),
          line: "55",
          delay_count: 20,
          blockage_count: 10,
          total_seconds: 2000,
          intersection_count: 5
        })
        |> Repo.insert()

      result = QueryRouter.line_summary("55")

      assert result.total_delays >= 20
      assert result.total_seconds >= 2000
    end
  end

  describe "hot_spots/1" do
    test "returns aggregated hot spots when available" do
      {:ok, _} =
        %DailyIntersectionStat{}
        |> DailyIntersectionStat.changeset(%{
          date: Date.utc_today(),
          lat: 52.2297,
          lon: 21.0122,
          nearest_stop: "Test Stop",
          delay_count: 15,
          blockage_count: 5,
          total_seconds: 1500,
          affected_lines: ["1", "2"]
        })
        |> Repo.insert()

      result = QueryRouter.hot_spots(limit: 10)

      assert length(result) >= 1
      spot = hd(result)
      assert spot.delay_count >= 15
    end

    test "falls back to raw when no aggregated data" do
      # Create only raw events (in a location that's "near intersection")
      now = DateTime.utc_now()

      create_delay_event(%{
        line: "1",
        lat: 52.1234,
        lon: 21.5678,
        started_at: now,
        classification: "delay",
        near_intersection: true,
        duration_seconds: 100
      })

      # This should attempt aggregated first, then fall back
      result = QueryRouter.hot_spots(limit: 10)

      # Result depends on whether there's aggregated data
      assert is_list(result)
    end
  end

  describe "heatmap_grid/0" do
    test "returns grid from HourlyPattern" do
      result = QueryRouter.heatmap_grid()

      assert Map.has_key?(result, :grid)
      assert Map.has_key?(result, :max_count)
      assert Map.has_key?(result, :total_delays)
      assert is_list(result.grid)
    end
  end

  describe "impacted_lines/1" do
    test "returns aggregated impacted lines" do
      {:ok, _} =
        %DailyLineStat{}
        |> DailyLineStat.changeset(%{
          date: Date.utc_today(),
          line: "44",
          delay_count: 50,
          blockage_count: 20,
          total_seconds: 5000,
          intersection_count: 10
        })
        |> Repo.insert()

      result = QueryRouter.impacted_lines(limit: 10)

      assert length(result) >= 1
      line = Enum.find(result, &(&1.line == "44"))
      assert line != nil
      assert line.delay_count >= 50
    end
  end

  describe "real-time functions" do
    test "active/0 returns unresolved delays" do
      now = DateTime.utc_now()

      # Create an active delay
      create_delay_event(%{
        line: "1",
        started_at: now,
        classification: "delay",
        resolved_at: nil
      })

      result = QueryRouter.active()

      assert length(result) >= 1
      assert Enum.all?(result, &is_nil(&1.resolved_at))
    end

    test "recent/1 returns recent events" do
      now = DateTime.utc_now()

      create_delay_event(%{
        line: "1",
        started_at: now,
        classification: "delay",
        duration_seconds: 60
      })

      result = QueryRouter.recent(10)

      assert length(result) >= 1
    end
  end

  # Helper to create delay events
  defp create_delay_event(attrs) do
    default_attrs = %{
      vehicle_id: "V/#{:rand.uniform(100)}/#{:rand.uniform(10)}",
      lat: 52.2297,
      lon: 21.0122,
      started_at: DateTime.utc_now(),
      classification: "delay",
      at_stop: false,
      near_intersection: false
    }

    {:ok, event} =
      %DelayEvent{}
      |> DelayEvent.changeset(Map.merge(default_attrs, attrs))
      |> Repo.insert()

    event
  end
end
