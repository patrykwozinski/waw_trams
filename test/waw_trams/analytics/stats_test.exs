defmodule WawTrams.Analytics.StatsTest do
  use WawTrams.DataCase, async: true

  alias WawTrams.Analytics.Stats
  alias WawTrams.DelayEvent

  describe "for_period/1" do
    test "groups by classification" do
      now = DateTime.utc_now()

      # Create delays
      for _ <- 1..3 do
        {:ok, event} =
          DelayEvent.create(%{
            vehicle_id: "V/1/1",
            lat: 52.23,
            lon: 21.01,
            started_at: DateTime.add(now, -60, :second),
            classification: "delay"
          })

        DelayEvent.resolve(event)
      end

      # Create blockages
      for _ <- 1..2 do
        {:ok, event} =
          DelayEvent.create(%{
            vehicle_id: "V/2/1",
            lat: 52.23,
            lon: 21.01,
            started_at: DateTime.add(now, -200, :second),
            classification: "blockage"
          })

        DelayEvent.resolve(event)
      end

      result = Stats.for_period(DateTime.add(now, -1, :hour))

      delays = Enum.find(result, &(&1.classification == "delay"))
      blockages = Enum.find(result, &(&1.classification == "blockage"))

      assert delays.count == 3
      assert blockages.count == 2
    end

    test "returns empty list when no data" do
      result = Stats.for_period(DateTime.utc_now())
      assert result == []
    end

    test "includes average duration" do
      now = DateTime.utc_now()

      {:ok, event} =
        DelayEvent.create(%{
          vehicle_id: "V/1/1",
          lat: 52.23,
          lon: 21.01,
          started_at: DateTime.add(now, -60, :second),
          classification: "delay"
        })

      DelayEvent.resolve(event)

      result = Stats.for_period(DateTime.add(now, -1, :hour))
      delays = Enum.find(result, &(&1.classification == "delay"))

      assert delays.avg_duration_seconds != nil
      assert delays.avg_duration_seconds >= 60
    end
  end

  describe "multi_cycle_count/1" do
    test "counts delays with multi_cycle flag" do
      now = DateTime.utc_now()

      # Create delay > 120s near intersection (will set multi_cycle)
      {:ok, event} =
        DelayEvent.create(%{
          vehicle_id: "V/1/1",
          lat: 52.23,
          lon: 21.01,
          started_at: DateTime.add(now, -150, :second),
          classification: "delay",
          near_intersection: true
        })

      DelayEvent.resolve(event)

      result = Stats.multi_cycle_count(DateTime.add(now, -1, :hour))

      assert result == 1
    end

    test "excludes non-multi-cycle delays" do
      now = DateTime.utc_now()

      # Create short delay (won't be multi_cycle)
      {:ok, event} =
        DelayEvent.create(%{
          vehicle_id: "V/1/1",
          lat: 52.23,
          lon: 21.01,
          started_at: DateTime.add(now, -60, :second),
          classification: "delay"
        })

      DelayEvent.resolve(event)

      result = Stats.multi_cycle_count(DateTime.add(now, -1, :hour))

      assert result == 0
    end
  end

  describe "total_time_lost/1" do
    test "sums all durations" do
      now = DateTime.utc_now()

      # Create two delays with known durations
      for offset <- [60, 90] do
        {:ok, event} =
          DelayEvent.create(%{
            vehicle_id: "V/1/#{offset}",
            lat: 52.23,
            lon: 21.01,
            started_at: DateTime.add(now, -offset, :second),
            classification: "delay"
          })

        DelayEvent.resolve(event)
      end

      result = Stats.total_time_lost(DateTime.add(now, -1, :hour))

      # Each resolve takes ~0s in test, so duration is ~60 and ~90
      assert result >= 150
    end

    test "returns 0 when no data" do
      result = Stats.total_time_lost(DateTime.utc_now())
      assert result == 0
    end
  end

  describe "summary/1" do
    test "returns all key stats" do
      now = DateTime.utc_now()

      {:ok, event} =
        DelayEvent.create(%{
          vehicle_id: "V/1/1",
          lat: 52.23,
          lon: 21.01,
          started_at: DateTime.add(now, -60, :second),
          classification: "delay"
        })

      DelayEvent.resolve(event)

      result = Stats.summary(DateTime.add(now, -1, :hour))

      assert Map.has_key?(result, :delay_count)
      assert Map.has_key?(result, :blockage_count)
      assert Map.has_key?(result, :total_count)
      assert Map.has_key?(result, :total_seconds)
      assert Map.has_key?(result, :total_hours)
      assert Map.has_key?(result, :multi_cycle_count)
    end

    test "calculates correct totals" do
      now = DateTime.utc_now()

      # 2 delays, 1 blockage
      for {class, i} <- [{"delay", 1}, {"delay", 2}, {"blockage", 3}] do
        {:ok, event} =
          DelayEvent.create(%{
            vehicle_id: "V/#{i}/1",
            lat: 52.23,
            lon: 21.01,
            started_at: DateTime.add(now, -60 * i, :second),
            classification: class
          })

        DelayEvent.resolve(event)
      end

      result = Stats.summary(DateTime.add(now, -1, :hour))

      assert result.delay_count == 2
      assert result.blockage_count == 1
      assert result.total_count == 3
    end
  end
end
