defmodule WawTrams.Audit.SummaryTest do
  use WawTrams.DataCase, async: true

  alias WawTrams.Audit.Summary
  alias WawTrams.{DelayEvent, HourlyIntersectionStat}

  setup do
    # Create a stop for location_name lookup
    {:ok, _} =
      Repo.query(
        "INSERT INTO stops (stop_id, name, geom, is_terminal, inserted_at, updated_at) VALUES ($1, $2, ST_SetSRID(ST_MakePoint($3, $4), 4326), $5, NOW(), NOW())",
        ["summary_stop", "Summary Test Stop", 21.01, 52.23, false]
      )

    :ok
  end

  # Helper to create aggregated data
  defp create_aggregated_stat(attrs) do
    default = %{
      date: Date.utc_today(),
      hour: DateTime.utc_now().hour,
      lat: 52.23,
      lon: 21.01,
      delay_count: 1,
      multi_cycle_count: 0,
      total_seconds: 60,
      cost_pln: 1.5,
      lines: ["19"]
    }

    HourlyIntersectionStat.upsert!(Map.merge(default, attrs))
  end

  describe "stats/1" do
    test "returns aggregate statistics from aggregated data" do
      # Insert aggregated data
      create_aggregated_stat(%{delay_count: 3, total_seconds: 180, cost_pln: 4.5})

      result = Summary.stats(since: DateTime.add(DateTime.utc_now(), -1, :day))

      assert result.total_delays == 3
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

      # Create a current hour raw event
      {:ok, event} =
        DelayEvent.create(%{
          vehicle_id: "V/19/1",
          line: "19",
          lat: 52.23,
          lon: 21.01,
          started_at: now,
          classification: "delay",
          near_intersection: true
        })

      DelayEvent.resolve(event)

      result = Summary.stats(since: DateTime.add(now, -2, :day))

      # Should have aggregated (2) + current hour (1) = 3
      assert result.total_delays == 3
    end

    test "returns zeros when no data" do
      result = Summary.stats()

      assert result.total_delays == 0
      assert result.total_seconds == 0
      assert result.cost.total == 0
    end

    test "filters by line" do
      # Create aggregated data for line 19
      create_aggregated_stat(%{lines: ["19"], delay_count: 2})

      # Create aggregated data for line 4
      create_aggregated_stat(%{lat: 52.24, lines: ["4"], delay_count: 1})

      result = Summary.stats(since: DateTime.add(DateTime.utc_now(), -1, :day), line: "19")

      assert result.total_delays == 2
    end

    test "counts multi-cycle delays" do
      create_aggregated_stat(%{delay_count: 2, multi_cycle_count: 1})

      result = Summary.stats(since: DateTime.add(DateTime.utc_now(), -1, :day))

      assert result.multi_cycle_count == 1
    end
  end

  describe "leaderboard/1" do
    test "returns top intersections by cost" do
      # Create aggregated data
      create_aggregated_stat(%{delay_count: 3, cost_pln: 10.0})

      result = Summary.leaderboard(since: DateTime.add(DateTime.utc_now(), -1, :day))

      assert length(result) >= 1
      first = hd(result)
      assert Map.has_key?(first, :lat)
      assert Map.has_key?(first, :lon)
      assert Map.has_key?(first, :cost)
      assert Map.has_key?(first, :severity)
      assert first.cost.total == 10.0
    end

    test "returns empty list when no intersection delays" do
      result = Summary.leaderboard()
      assert result == []
    end

    test "respects limit" do
      # Create aggregated data at multiple locations
      for i <- 1..5 do
        create_aggregated_stat(%{
          lat: 52.20 + 0.01 * i,
          lon: 21.00 + 0.01 * i,
          cost_pln: 5.0 * i
        })
      end

      result = Summary.leaderboard(since: DateTime.add(DateTime.utc_now(), -1, :day), limit: 3)

      assert length(result) == 3
    end

    test "assigns severity based on multi_cycle percentage" do
      # 100% multi-cycle = red severity
      create_aggregated_stat(%{delay_count: 3, multi_cycle_count: 3, cost_pln: 15.0})

      result = Summary.leaderboard(since: DateTime.add(DateTime.utc_now(), -1, :day))

      assert length(result) >= 1
      assert hd(result).severity == :red
    end

    test "orders by cost descending" do
      create_aggregated_stat(%{lat: 52.23, lon: 21.01, cost_pln: 5.0})
      create_aggregated_stat(%{lat: 52.24, lon: 21.02, cost_pln: 15.0})
      create_aggregated_stat(%{lat: 52.25, lon: 21.03, cost_pln: 10.0})

      result = Summary.leaderboard(since: DateTime.add(DateTime.utc_now(), -1, :day))

      costs = Enum.map(result, & &1.cost.total)
      assert costs == Enum.sort(costs, :desc)
    end
  end
end
