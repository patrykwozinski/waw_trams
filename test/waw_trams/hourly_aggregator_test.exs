defmodule WawTrams.HourlyAggregatorTest do
  use WawTrams.DataCase, async: false

  alias WawTrams.{
    HourlyAggregator,
    DelayEvent,
    DailyIntersectionStat,
    DailyLineStat,
    HourlyPattern
  }

  # Test hour: 2 hours ago to avoid current hour issues
  defp test_hour do
    DateTime.utc_now()
    |> DateTime.add(-2, :hour)
    |> DateTime.truncate(:second)
    |> Map.put(:minute, 0)
    |> Map.put(:second, 0)
  end

  defp create_test_event(attrs) do
    hour = test_hour()

    default_attrs = %{
      vehicle_id: "V/17/#{:rand.uniform(100)}",
      line: "17",
      lat: 52.2297,
      lon: 21.0122,
      started_at: DateTime.add(hour, :rand.uniform(3000), :second),
      resolved_at: DateTime.add(hour, :rand.uniform(3000) + 60, :second),
      duration_seconds: 120,
      classification: "delay",
      at_stop: false,
      near_intersection: true
    }

    {:ok, event} = DelayEvent.create(Map.merge(default_attrs, attrs))
    event
  end

  describe "aggregate_now/1" do
    test "aggregates events for a given hour" do
      hour = test_hour()

      # Create some test events
      _event1 = create_test_event(%{line: "17", classification: "delay", duration_seconds: 60})

      _event2 =
        create_test_event(%{line: "17", classification: "blockage", duration_seconds: 200})

      _event3 = create_test_event(%{line: "25", classification: "delay", duration_seconds: 90})

      # Run aggregation
      assert {:ok, stats} = HourlyAggregator.aggregate_now(hour)

      assert stats.event_count == 3
      # 17 and 25
      assert stats.lines == 2
      assert stats.intersections >= 1
    end

    test "creates daily_line_stats entries" do
      hour = test_hour()
      date = DateTime.to_date(hour)

      # Create events for line 17
      _event1 = create_test_event(%{line: "17", classification: "delay", duration_seconds: 60})
      _event2 = create_test_event(%{line: "17", classification: "delay", duration_seconds: 90})

      # Run aggregation
      assert {:ok, _stats} = HourlyAggregator.aggregate_now(hour)

      # Check daily_line_stats was created
      line_stat = Repo.get_by(DailyLineStat, date: date, line: "17")
      assert line_stat != nil
      assert line_stat.delay_count >= 2
    end

    test "creates hourly_patterns entries" do
      hour = test_hour()

      # Create events
      _event = create_test_event(%{classification: "delay", duration_seconds: 100})

      # Get initial pattern count
      day_of_week = Date.day_of_week(DateTime.to_date(hour))
      initial_pattern = Repo.get_by(HourlyPattern, day_of_week: day_of_week, hour: hour.hour)
      initial_count = if initial_pattern, do: initial_pattern.delay_count, else: 0

      # Run aggregation
      assert {:ok, _stats} = HourlyAggregator.aggregate_now(hour)

      # Check hourly_patterns was updated
      updated_pattern = Repo.get_by(HourlyPattern, day_of_week: day_of_week, hour: hour.hour)
      assert updated_pattern != nil
      assert updated_pattern.delay_count >= initial_count
    end

    test "creates daily_intersection_stats for events near intersections" do
      hour = test_hour()
      date = DateTime.to_date(hour)

      # Create event near intersection
      _event =
        create_test_event(%{
          lat: 52.2300,
          lon: 21.0100,
          near_intersection: true,
          classification: "delay",
          duration_seconds: 120
        })

      # Run aggregation
      assert {:ok, _stats} = HourlyAggregator.aggregate_now(hour)

      # Check daily_intersection_stats was created
      intersection_stats = Repo.all(from d in DailyIntersectionStat, where: d.date == ^date)
      assert length(intersection_stats) >= 1
    end

    test "returns zero counts for hour with no events" do
      # Use a far past hour with no events
      empty_hour =
        DateTime.utc_now()
        |> DateTime.add(-100, :hour)
        |> DateTime.truncate(:second)
        |> Map.put(:minute, 0)
        |> Map.put(:second, 0)

      assert {:ok, stats} = HourlyAggregator.aggregate_now(empty_hour)

      assert stats.event_count == 0
      assert stats.intersections == 0
      assert stats.lines == 0
    end
  end

  describe "status/0" do
    test "returns aggregator state" do
      # Start the aggregator if not running
      status = HourlyAggregator.status()

      assert is_map(status)
      assert Map.has_key?(status, :last_aggregated)
      assert Map.has_key?(status, :catching_up)
    end
  end

  describe "aggregation logic" do
    test "groups events by line correctly" do
      hour = test_hour()

      # Create events for different lines
      _e1 = create_test_event(%{line: "1", classification: "delay", duration_seconds: 60})
      _e2 = create_test_event(%{line: "1", classification: "delay", duration_seconds: 60})
      _e3 = create_test_event(%{line: "17", classification: "blockage", duration_seconds: 200})

      assert {:ok, stats} = HourlyAggregator.aggregate_now(hour)

      assert stats.event_count == 3
      # line 1 and line 17
      assert stats.lines == 2
    end

    test "stores duration in daily_line_stats" do
      hour = test_hour()
      date = DateTime.to_date(hour)

      _e1 = create_test_event(%{line: "77", duration_seconds: 100})
      _e2 = create_test_event(%{line: "77", duration_seconds: 150})

      assert {:ok, _stats} = HourlyAggregator.aggregate_now(hour)

      # Check the daily_line_stats has the duration
      line_stat = Repo.get_by(DailyLineStat, date: date, line: "77")
      assert line_stat != nil
      assert line_stat.total_seconds >= 250
    end

    test "handles nil duration_seconds gracefully" do
      hour = test_hour()

      # Create event without duration (active event)
      {:ok, _event} =
        DelayEvent.create(%{
          vehicle_id: "V/99/1",
          line: "99",
          lat: 52.2297,
          lon: 21.0122,
          started_at: DateTime.add(hour, 100, :second),
          classification: "delay",
          at_stop: false,
          near_intersection: false,
          duration_seconds: nil
        })

      # Should not crash
      assert {:ok, _stats} = HourlyAggregator.aggregate_now(hour)
    end
  end

  describe "by_hour breakdown" do
    test "stores hour breakdown in daily_line_stats" do
      hour = test_hour()
      date = DateTime.to_date(hour)

      _event = create_test_event(%{line: "33", classification: "delay", duration_seconds: 120})

      assert {:ok, _stats} = HourlyAggregator.aggregate_now(hour)

      line_stat = Repo.get_by(DailyLineStat, date: date, line: "33")
      assert line_stat != nil
      assert is_map(line_stat.by_hour)

      hour_key = to_string(hour.hour)
      assert Map.has_key?(line_stat.by_hour, hour_key)

      hour_data = line_stat.by_hour[hour_key]
      assert hour_data["delay_count"] >= 1
    end
  end
end
