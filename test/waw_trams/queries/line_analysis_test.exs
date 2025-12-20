defmodule WawTrams.Queries.LineAnalysisTest do
  use WawTrams.DataCase, async: true

  alias WawTrams.Queries.LineAnalysis
  alias WawTrams.DelayEvent

  describe "delays_by_hour/2" do
    test "groups delays by hour" do
      now = DateTime.utc_now()

      # Create delays at different hours
      {:ok, event1} =
        DelayEvent.create(%{
          vehicle_id: "V/19/1",
          line: "19",
          lat: 52.23,
          lon: 21.01,
          started_at: DateTime.add(now, -60, :second),
          classification: "delay"
        })

      DelayEvent.resolve(event1)

      result = LineAnalysis.delays_by_hour("19", since: DateTime.add(now, -1, :hour))

      assert length(result) >= 1
      first = hd(result)
      assert Map.has_key?(first, :hour)
      assert Map.has_key?(first, :delay_count)
      assert Map.has_key?(first, :total_seconds)
    end

    test "includes intersection_delays count" do
      now = DateTime.utc_now()

      {:ok, event} =
        DelayEvent.create(%{
          vehicle_id: "V/19/1",
          line: "19",
          lat: 52.23,
          lon: 21.01,
          started_at: DateTime.add(now, -60, :second),
          classification: "delay",
          near_intersection: true
        })

      DelayEvent.resolve(event)

      result = LineAnalysis.delays_by_hour("19", since: DateTime.add(now, -1, :hour))
      first = hd(result)

      assert first.intersection_delays == 1
    end

    test "returns empty list for line with no data" do
      result = LineAnalysis.delays_by_hour("99")
      assert result == []
    end
  end

  describe "summary/2" do
    test "returns overall stats for a line" do
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

      result = LineAnalysis.summary("19", since: DateTime.add(now, -1, :hour))

      assert result.total_delays == 1
      assert result.total_seconds >= 60
      assert result.avg_seconds >= 60
    end

    test "returns zeros for line with no data" do
      result = LineAnalysis.summary("99")

      assert result.total_delays == 0
      assert result.total_seconds == 0
      assert result.avg_seconds == 0
    end
  end

  describe "hot_spots/2" do
    setup do
      # Create a stop for location_name lookup
      {:ok, _} =
        Repo.query(
          "INSERT INTO stops (stop_id, name, geom, is_terminal, inserted_at, updated_at) VALUES ($1, $2, ST_SetSRID(ST_MakePoint($3, $4), 4326), $5, NOW(), NOW())",
          ["1001", "Test Stop", 21.01, 52.23, false]
        )

      :ok
    end

    test "clusters nearby intersection delays" do
      now = DateTime.utc_now()

      # Create delays near same intersection
      for i <- 1..3 do
        {:ok, event} =
          DelayEvent.create(%{
            vehicle_id: "V/19/#{i}",
            line: "19",
            lat: 52.23 + i * 0.0001,
            lon: 21.01 + i * 0.0001,
            started_at: DateTime.add(now, -60 * i, :second),
            classification: "delay",
            near_intersection: true
          })

        DelayEvent.resolve(event)
      end

      result = LineAnalysis.hot_spots("19", since: DateTime.add(now, -1, :hour))

      # Should cluster into 1 or 2 spots (depending on spread)
      assert length(result) >= 1
      first = hd(result)
      assert first.event_count >= 1
    end

    test "returns empty for line with no intersection delays" do
      now = DateTime.utc_now()

      {:ok, event} =
        DelayEvent.create(%{
          vehicle_id: "V/19/1",
          line: "19",
          lat: 52.23,
          lon: 21.01,
          started_at: DateTime.add(now, -60, :second),
          classification: "delay",
          near_intersection: false
        })

      DelayEvent.resolve(event)

      result = LineAnalysis.hot_spots("19", since: DateTime.add(now, -1, :hour))
      assert result == []
    end
  end

  describe "lines_with_delays/1" do
    test "returns sorted list of lines" do
      now = DateTime.utc_now()

      for line <- ["19", "4", "25"] do
        {:ok, event} =
          DelayEvent.create(%{
            vehicle_id: "V/#{line}/1",
            line: line,
            lat: 52.23,
            lon: 21.01,
            started_at: DateTime.add(now, -60, :second),
            classification: "delay"
          })

        DelayEvent.resolve(event)
      end

      result = LineAnalysis.lines_with_delays(since: DateTime.add(now, -1, :hour))

      assert result == ["4", "19", "25"]
    end

    test "returns empty list when no delays" do
      result = LineAnalysis.lines_with_delays()
      assert result == []
    end
  end
end
