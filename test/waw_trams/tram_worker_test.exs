defmodule WawTrams.TramWorkerTest do
  use ExUnit.Case, async: true

  alias WawTrams.TramWorker

  describe "calculate_speed/1" do
    test "returns nil with less than 2 positions" do
      assert TramWorker.calculate_speed([]) == nil
      assert TramWorker.calculate_speed([%{lat: 52.23, lon: 21.01, timestamp: DateTime.utc_now()}]) == nil
    end

    test "calculates speed from two positions" do
      now = DateTime.utc_now()
      ten_seconds_ago = DateTime.add(now, -10, :second)

      # ~100m apart, 10 seconds = ~36 km/h
      positions = [
        %{lat: 52.2300, lon: 21.0100, timestamp: now},
        %{lat: 52.2291, lon: 21.0100, timestamp: ten_seconds_ago}
      ]

      speed = TramWorker.calculate_speed(positions)
      assert speed > 30 and speed < 40
    end

    test "returns nil when timestamps are equal" do
      now = DateTime.utc_now()

      positions = [
        %{lat: 52.2300, lon: 21.0100, timestamp: now},
        %{lat: 52.2291, lon: 21.0100, timestamp: now}
      ]

      assert TramWorker.calculate_speed(positions) == nil
    end

    test "calculates zero speed for same location" do
      now = DateTime.utc_now()
      ten_seconds_ago = DateTime.add(now, -10, :second)

      positions = [
        %{lat: 52.2300, lon: 21.0100, timestamp: now},
        %{lat: 52.2300, lon: 21.0100, timestamp: ten_seconds_ago}
      ]

      assert TramWorker.calculate_speed(positions) == 0.0
    end

    test "handles slow tram speed (< 3 km/h threshold)" do
      now = DateTime.utc_now()
      ten_seconds_ago = DateTime.add(now, -10, :second)

      # ~5m in 10 seconds = ~1.8 km/h (stopped)
      positions = [
        %{lat: 52.23000, lon: 21.01000, timestamp: now},
        %{lat: 52.23005, lon: 21.01000, timestamp: ten_seconds_ago}
      ]

      speed = TramWorker.calculate_speed(positions)
      assert speed < 3.0
    end
  end

  describe "haversine_distance/4" do
    test "returns zero for same coordinates" do
      assert TramWorker.haversine_distance(52.23, 21.01, 52.23, 21.01) == 0.0
    end

    test "calculates distance in kilometers" do
      # Warsaw center to ~1km north
      distance = TramWorker.haversine_distance(52.2297, 21.0122, 52.2387, 21.0122)
      # Should be ~1km
      assert distance > 0.9 and distance < 1.1
    end

    test "is symmetric" do
      d1 = TramWorker.haversine_distance(52.23, 21.01, 52.24, 21.02)
      d2 = TramWorker.haversine_distance(52.24, 21.02, 52.23, 21.01)
      assert_in_delta d1, d2, 0.0001
    end

    test "calculates ~50m correctly" do
      # 50m north
      distance = TramWorker.haversine_distance(52.2297, 21.0122, 52.23015, 21.0122)
      assert_in_delta distance, 0.05, 0.01  # ~50m = 0.05km
    end
  end

  describe "classify_delay/2" do
    # AT STOP scenarios
    test "at stop < 180s returns :normal_dwell" do
      assert TramWorker.classify_delay(0, true) == :normal_dwell
      assert TramWorker.classify_delay(60, true) == :normal_dwell
      assert TramWorker.classify_delay(120, true) == :normal_dwell
      assert TramWorker.classify_delay(179, true) == :normal_dwell
    end

    test "at stop >= 180s returns :blockage" do
      assert TramWorker.classify_delay(180, true) == :blockage
      assert TramWorker.classify_delay(300, true) == :blockage
      assert TramWorker.classify_delay(600, true) == :blockage
    end

    # NOT AT STOP scenarios
    test "not at stop < 30s returns :brief_stop" do
      assert TramWorker.classify_delay(0, false) == :brief_stop
      assert TramWorker.classify_delay(15, false) == :brief_stop
      assert TramWorker.classify_delay(29, false) == :brief_stop
    end

    test "not at stop >= 30s returns :delay" do
      assert TramWorker.classify_delay(30, false) == :delay
      assert TramWorker.classify_delay(60, false) == :delay
      assert TramWorker.classify_delay(300, false) == :delay
    end
  end

  describe "should_persist?/1" do
    test "persists :blockage" do
      assert TramWorker.should_persist?(:blockage) == true
    end

    test "persists :delay" do
      assert TramWorker.should_persist?(:delay) == true
    end

    test "does not persist :normal_dwell" do
      assert TramWorker.should_persist?(:normal_dwell) == false
    end

    test "does not persist :brief_stop" do
      assert TramWorker.should_persist?(:brief_stop) == false
    end
  end

  describe "classification integration" do
    test "at stop for 2 minutes is not persisted" do
      classification = TramWorker.classify_delay(120, true)
      assert classification == :normal_dwell
      assert TramWorker.should_persist?(classification) == false
    end

    test "at stop for 3+ minutes is persisted as blockage" do
      classification = TramWorker.classify_delay(180, true)
      assert classification == :blockage
      assert TramWorker.should_persist?(classification) == true
    end

    test "not at stop for 20 seconds is not persisted" do
      classification = TramWorker.classify_delay(20, false)
      assert classification == :brief_stop
      assert TramWorker.should_persist?(classification) == false
    end

    test "not at stop for 30+ seconds is persisted as delay" do
      classification = TramWorker.classify_delay(35, false)
      assert classification == :delay
      assert TramWorker.should_persist?(classification) == true
    end
  end
end
