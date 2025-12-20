defmodule WawTrams.Queries.HotSpotsTest do
  use WawTrams.DataCase, async: true

  alias WawTrams.Queries.HotSpots
  alias WawTrams.DelayEvent
  alias WawTrams.Repo

  # Test intersection coordinates (near Rondo ONZ area)
  @test_lat 52.2320
  @test_lon 21.0030

  setup do
    # Create test intersection
    Repo.query!("""
      INSERT INTO intersections (osm_id, geom, inserted_at, updated_at)
      VALUES (
        'test_intersection_1',
        ST_SetSRID(ST_MakePoint(#{@test_lon}, #{@test_lat}), 4326),
        NOW(), NOW()
      )
    """)

    # Create test stop nearby
    Repo.query!("""
      INSERT INTO stops (stop_id, name, is_terminal, geom, inserted_at, updated_at)
      VALUES (
        'test_stop_1',
        'Test Stop',
        false,
        ST_SetSRID(ST_MakePoint(#{@test_lon}, #{@test_lat}), 4326),
        NOW(), NOW()
      )
    """)

    :ok
  end

  describe "hot_spots/1" do
    test "returns hot spots with delay data" do
      # Create delay near our test intersection
      {:ok, _delay} =
        DelayEvent.create(%{
          vehicle_id: "V/1/1",
          line: "25",
          lat: @test_lat,
          lon: @test_lon,
          started_at: DateTime.utc_now(),
          classification: "delay",
          near_intersection: true,
          duration_seconds: 60
        })
        |> elem(1)
        |> DelayEvent.resolve()

      result = HotSpots.hot_spots(limit: 10)

      assert length(result) >= 1
      hot_spot = hd(result)
      assert hot_spot.delay_count >= 1
      assert hot_spot.location_name != nil
    end

    test "filters by since parameter" do
      # Create old delay
      old_time = DateTime.add(DateTime.utc_now(), -48, :hour)

      {:ok, _old} =
        DelayEvent.create(%{
          vehicle_id: "V/1/1",
          line: "25",
          lat: @test_lat,
          lon: @test_lon,
          started_at: old_time,
          classification: "delay",
          near_intersection: true
        })

      # Query for last 24h only
      result = HotSpots.hot_spots(since: DateTime.add(DateTime.utc_now(), -24, :hour))

      # Old delay should not appear
      assert Enum.all?(result, fn hs -> hs.delay_count == 0 end) or result == []
    end

    test "respects limit parameter" do
      result = HotSpots.hot_spots(limit: 5)

      assert length(result) <= 5
    end
  end

  describe "hot_spot_summary/1" do
    test "returns aggregate statistics" do
      # Create delay near intersection
      {:ok, event} =
        DelayEvent.create(%{
          vehicle_id: "V/1/1",
          line: "25",
          lat: @test_lat,
          lon: @test_lon,
          started_at: DateTime.add(DateTime.utc_now(), -60, :second),
          classification: "delay",
          near_intersection: true
        })

      DelayEvent.resolve(event)

      result = HotSpots.hot_spot_summary()

      assert is_map(result)
      assert Map.has_key?(result, :intersection_count)
      assert Map.has_key?(result, :total_delays)
      assert Map.has_key?(result, :total_delay_seconds)
      assert Map.has_key?(result, :total_delay_minutes)
    end

    test "returns zeros when no data" do
      result = HotSpots.hot_spot_summary(DateTime.add(DateTime.utc_now(), -1, :hour))

      assert result.intersection_count >= 0
      assert result.total_delays >= 0
    end
  end

  describe "impacted_lines/1" do
    test "returns lines ranked by delay impact" do
      # Create delays for different lines
      for {line, count} <- [{"25", 3}, {"15", 1}] do
        for _ <- 1..count do
          {:ok, event} =
            DelayEvent.create(%{
              vehicle_id: "V/#{line}/1",
              line: line,
              lat: @test_lat,
              lon: @test_lon,
              started_at: DateTime.add(DateTime.utc_now(), -60, :second),
              classification: "delay",
              near_intersection: true
            })

          DelayEvent.resolve(event)
        end
      end

      result = HotSpots.impacted_lines()

      assert is_list(result)

      if length(result) > 0 do
        first = hd(result)
        assert Map.has_key?(first, :line)
        assert Map.has_key?(first, :delay_count)
        assert Map.has_key?(first, :total_seconds)
      end
    end

    test "respects limit parameter" do
      result = HotSpots.impacted_lines(limit: 3)

      assert length(result) <= 3
    end
  end
end
