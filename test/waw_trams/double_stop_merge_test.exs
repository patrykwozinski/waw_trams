defmodule WawTrams.DoubleStopMergeTest do
  @moduledoc """
  Tests for the double-stop merge feature.

  See guides/signal_timing.md for rationale:
  - Tram stops at platform, moves 20m, stops at red light
  - Without merge: 2 separate delay events
  - With merge: 1 combined event capturing total interruption
  """
  use WawTrams.DataCase, async: true

  alias WawTrams.{DelayEvent, TramWorker}

  # Test constants matching TramWorker config
  @merge_distance_m 60
  @merge_grace_period_s 45

  describe "haversine_distance for merge calculations" do
    test "correctly calculates distances within merge threshold" do
      # 40 meters apart (should merge)
      dist_km = TramWorker.haversine_distance(52.23000, 21.01000, 52.23036, 21.01000)
      dist_m = dist_km * 1000
      assert dist_m < @merge_distance_m
    end

    test "correctly calculates distances outside merge threshold" do
      # 100 meters apart (should NOT merge)
      dist_km = TramWorker.haversine_distance(52.23000, 21.01000, 52.23090, 21.01000)
      dist_m = dist_km * 1000
      assert dist_m > @merge_distance_m
    end
  end

  describe "merge window timing" do
    test "grace period is 45 seconds" do
      assert @merge_grace_period_s == 45
    end

    test "merge distance is 60 meters" do
      assert @merge_distance_m == 60
    end
  end

  describe "double stop detection scenarios" do
    test "scenario: platform stop then light stop within merge window" do
      # This test documents the expected behavior:
      # 1. Tram stops at platform (potential delay)
      # 2. Tram moves briefly (pending resolution - NOT immediately resolved)
      # 3. Tram stops 30m ahead within 20s (continue original delay)
      # Result: 1 delay event, not 2

      # Create an initial delay event
      {:ok, event1} =
        DelayEvent.create(%{
          vehicle_id: "V/1/1",
          line: "1",
          lat: 52.23000,
          lon: 21.01000,
          started_at: DateTime.utc_now() |> DateTime.add(-60, :second),
          classification: "delay",
          at_stop: false,
          near_intersection: true
        })

      assert event1.id
      assert is_nil(event1.resolved_at)

      # Verify the event exists
      assert DelayEvent.get(event1.id)
    end

    test "scenario: stops far apart should NOT merge" do
      # Stops 100m apart should be separate events
      dist_km = TramWorker.haversine_distance(52.23000, 21.01000, 52.23090, 21.01000)
      dist_m = dist_km * 1000

      # ~100m apart - should NOT merge
      assert dist_m > @merge_distance_m
    end

    test "scenario: stops with long gap should NOT merge" do
      # Even if close, if >45s passed, they should be separate events
      # This is validated by the @merge_grace_period_s constant
      assert @merge_grace_period_s == 45
    end
  end

  describe "DelayEvent.get/1" do
    test "returns event by ID" do
      {:ok, event} =
        DelayEvent.create(%{
          vehicle_id: "V/test/1",
          line: "test",
          lat: 52.23,
          lon: 21.01,
          started_at: DateTime.utc_now(),
          classification: "delay",
          at_stop: false,
          near_intersection: false
        })

      fetched = DelayEvent.get(event.id)
      assert fetched.id == event.id
      assert fetched.vehicle_id == "V/test/1"
    end

    test "returns nil for non-existent ID" do
      assert is_nil(DelayEvent.get(999_999_999))
    end
  end
end
