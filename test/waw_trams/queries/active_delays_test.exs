defmodule WawTrams.Queries.ActiveDelaysTest do
  use WawTrams.DataCase, async: true

  alias WawTrams.Queries.ActiveDelays
  alias WawTrams.DelayEvent

  describe "active/0" do
    test "returns only unresolved delays" do
      # Create resolved delay
      {:ok, _resolved} =
        DelayEvent.create(%{
          vehicle_id: "V/1/1",
          lat: 52.23,
          lon: 21.01,
          started_at: DateTime.add(DateTime.utc_now(), -60, :second),
          classification: "delay"
        })
        |> elem(1)
        |> DelayEvent.resolve()

      # Create active delay
      {:ok, active} =
        DelayEvent.create(%{
          vehicle_id: "V/2/2",
          lat: 52.24,
          lon: 21.02,
          started_at: DateTime.utc_now(),
          classification: "delay"
        })

      result = ActiveDelays.active()

      assert length(result) == 1
      assert hd(result).id == active.id
    end

    test "orders by started_at desc" do
      now = DateTime.utc_now()

      {:ok, older} =
        DelayEvent.create(%{
          vehicle_id: "V/1/1",
          lat: 52.23,
          lon: 21.01,
          started_at: DateTime.add(now, -120, :second),
          classification: "delay"
        })

      {:ok, newer} =
        DelayEvent.create(%{
          vehicle_id: "V/2/2",
          lat: 52.24,
          lon: 21.02,
          started_at: now,
          classification: "delay"
        })

      result = ActiveDelays.active()

      assert length(result) == 2
      assert Enum.at(result, 0).id == newer.id
      assert Enum.at(result, 1).id == older.id
    end

    test "returns empty list when no active delays" do
      assert ActiveDelays.active() == []
    end
  end

  describe "recent/1" do
    test "returns both active and resolved delays" do
      {:ok, _resolved} =
        DelayEvent.create(%{
          vehicle_id: "V/1/1",
          lat: 52.23,
          lon: 21.01,
          started_at: DateTime.add(DateTime.utc_now(), -60, :second),
          classification: "delay"
        })
        |> elem(1)
        |> DelayEvent.resolve()

      {:ok, _active} =
        DelayEvent.create(%{
          vehicle_id: "V/2/2",
          lat: 52.24,
          lon: 21.02,
          started_at: DateTime.utc_now(),
          classification: "delay"
        })

      result = ActiveDelays.recent()

      assert length(result) == 2
    end

    test "respects limit parameter" do
      for i <- 1..5 do
        DelayEvent.create(%{
          vehicle_id: "V/#{i}/1",
          lat: 52.23,
          lon: 21.01,
          started_at: DateTime.utc_now(),
          classification: "delay"
        })
      end

      result = ActiveDelays.recent(3)

      assert length(result) == 3
    end
  end

  describe "count_active/0" do
    test "returns count of unresolved delays" do
      for i <- 1..3 do
        DelayEvent.create(%{
          vehicle_id: "V/#{i}/1",
          lat: 52.23,
          lon: 21.01,
          started_at: DateTime.utc_now(),
          classification: "delay"
        })
      end

      assert ActiveDelays.count_active() == 3
    end

    test "excludes resolved delays from count" do
      {:ok, event} =
        DelayEvent.create(%{
          vehicle_id: "V/1/1",
          lat: 52.23,
          lon: 21.01,
          started_at: DateTime.add(DateTime.utc_now(), -60, :second),
          classification: "delay"
        })

      DelayEvent.resolve(event)

      assert ActiveDelays.count_active() == 0
    end
  end

  describe "count_today/0" do
    test "counts delays started today" do
      # Create delay from today
      DelayEvent.create(%{
        vehicle_id: "V/1/1",
        lat: 52.23,
        lon: 21.01,
        started_at: DateTime.utc_now(),
        classification: "delay"
      })

      assert ActiveDelays.count_today() >= 1
    end
  end

  describe "resolved_since/2" do
    test "returns only resolved delays after timestamp" do
      now = DateTime.utc_now()
      since = DateTime.add(now, -300, :second)

      # Create and resolve a delay
      {:ok, event} =
        DelayEvent.create(%{
          vehicle_id: "V/1/1",
          lat: 52.23,
          lon: 21.01,
          started_at: DateTime.add(now, -60, :second),
          classification: "delay"
        })

      {:ok, _resolved} = DelayEvent.resolve(event)

      result = ActiveDelays.resolved_since(since)

      assert length(result) == 1
    end

    test "excludes active delays" do
      now = DateTime.utc_now()
      since = DateTime.add(now, -300, :second)

      # Create active delay (not resolved)
      DelayEvent.create(%{
        vehicle_id: "V/1/1",
        lat: 52.23,
        lon: 21.01,
        started_at: now,
        classification: "delay"
      })

      result = ActiveDelays.resolved_since(since)

      assert result == []
    end
  end
end
