defmodule WawTrams.DelayEventTest do
  use WawTrams.DataCase, async: true

  alias WawTrams.DelayEvent

  @valid_attrs %{
    vehicle_id: "V/17/5",
    line: "17",
    lat: 52.2297,
    lon: 21.0122,
    started_at: DateTime.utc_now(),
    classification: "delay",
    at_stop: false,
    near_intersection: true
  }

  describe "create/1" do
    test "creates a delay event with valid attrs" do
      assert {:ok, event} = DelayEvent.create(@valid_attrs)
      assert event.vehicle_id == "V/17/5"
      assert event.line == "17"
      assert event.classification == "delay"
      assert event.at_stop == false
      assert event.near_intersection == true
      assert is_nil(event.resolved_at)
    end

    test "requires vehicle_id" do
      attrs = Map.delete(@valid_attrs, :vehicle_id)
      assert {:error, changeset} = DelayEvent.create(attrs)
      assert "can't be blank" in errors_on(changeset).vehicle_id
    end

    test "requires lat/lon" do
      attrs = @valid_attrs |> Map.delete(:lat) |> Map.delete(:lon)
      assert {:error, changeset} = DelayEvent.create(attrs)
      assert "can't be blank" in errors_on(changeset).lat
      assert "can't be blank" in errors_on(changeset).lon
    end

    test "requires started_at" do
      attrs = Map.delete(@valid_attrs, :started_at)
      assert {:error, changeset} = DelayEvent.create(attrs)
      assert "can't be blank" in errors_on(changeset).started_at
    end

    test "requires classification" do
      attrs = Map.delete(@valid_attrs, :classification)
      assert {:error, changeset} = DelayEvent.create(attrs)
      assert "can't be blank" in errors_on(changeset).classification
    end

    test "validates classification values" do
      attrs = Map.put(@valid_attrs, :classification, "invalid")
      assert {:error, changeset} = DelayEvent.create(attrs)
      assert "is invalid" in errors_on(changeset).classification
    end

    test "accepts blockage classification" do
      attrs = Map.put(@valid_attrs, :classification, "blockage")
      assert {:ok, event} = DelayEvent.create(attrs)
      assert event.classification == "blockage"
    end
  end

  describe "find_unresolved/1" do
    test "finds unresolved delay for vehicle" do
      {:ok, _event} = DelayEvent.create(@valid_attrs)

      found = DelayEvent.find_unresolved("V/17/5")
      assert found.vehicle_id == "V/17/5"
      assert is_nil(found.resolved_at)
    end

    test "returns nil when no unresolved delay" do
      assert DelayEvent.find_unresolved("V/99/99") == nil
    end

    test "does not find resolved delays" do
      {:ok, event} = DelayEvent.create(@valid_attrs)
      {:ok, _resolved} = DelayEvent.resolve(event)

      assert DelayEvent.find_unresolved("V/17/5") == nil
    end
  end

  describe "resolve/1" do
    test "sets resolved_at and duration" do
      started_at = DateTime.add(DateTime.utc_now(), -60, :second)
      attrs = Map.put(@valid_attrs, :started_at, started_at)
      {:ok, event} = DelayEvent.create(attrs)

      {:ok, resolved} = DelayEvent.resolve(event)

      assert not is_nil(resolved.resolved_at)
      assert resolved.duration_seconds >= 60
    end

    test "calculates correct duration" do
      started_at = DateTime.add(DateTime.utc_now(), -120, :second)
      attrs = Map.put(@valid_attrs, :started_at, started_at)
      {:ok, event} = DelayEvent.create(attrs)

      {:ok, resolved} = DelayEvent.resolve(event)

      # Should be ~120 seconds (allow some margin for test execution)
      assert resolved.duration_seconds >= 119
      assert resolved.duration_seconds <= 125
    end
  end

  describe "active/0" do
    test "returns unresolved delays" do
      {:ok, _event1} = DelayEvent.create(@valid_attrs)
      {:ok, event2} = DelayEvent.create(Map.put(@valid_attrs, :vehicle_id, "V/18/1"))
      {:ok, _resolved} = DelayEvent.resolve(event2)

      active = DelayEvent.active()

      assert length(active) == 1
      assert hd(active).vehicle_id == "V/17/5"
    end

    test "returns empty list when no active delays" do
      assert DelayEvent.active() == []
    end
  end

  describe "recent/1" do
    test "returns delays ordered by started_at desc" do
      now = DateTime.utc_now()

      {:ok, _older} =
        DelayEvent.create(
          Map.merge(@valid_attrs, %{
            vehicle_id: "V/1/1",
            started_at: DateTime.add(now, -60, :second)
          })
        )

      {:ok, _newer} =
        DelayEvent.create(Map.merge(@valid_attrs, %{vehicle_id: "V/2/2", started_at: now}))

      recent = DelayEvent.recent(10)

      assert length(recent) == 2
      # newer first
      assert hd(recent).vehicle_id == "V/2/2"
    end

    test "respects limit" do
      for i <- 1..5 do
        DelayEvent.create(Map.put(@valid_attrs, :vehicle_id, "V/#{i}/#{i}"))
      end

      assert length(DelayEvent.recent(3)) == 3
    end
  end

  describe "stats/1" do
    test "returns stats grouped by classification" do
      # Create some delays
      {:ok, d1} = DelayEvent.create(@valid_attrs)
      {:ok, _} = DelayEvent.resolve(d1)

      {:ok, d2} = DelayEvent.create(Map.put(@valid_attrs, :vehicle_id, "V/2/2"))
      {:ok, _} = DelayEvent.resolve(d2)

      {:ok, _} =
        DelayEvent.create(
          Map.merge(@valid_attrs, %{vehicle_id: "V/3/3", classification: "blockage"})
        )

      stats = DelayEvent.stats()

      delay_stat = Enum.find(stats, &(&1.classification == "delay"))
      blockage_stat = Enum.find(stats, &(&1.classification == "blockage"))

      assert delay_stat.count == 2
      assert blockage_stat.count == 1
    end
  end

  describe "resolve_orphaned/0" do
    test "resolves all unresolved delay events" do
      # Create several unresolved delays
      started_at = DateTime.add(DateTime.utc_now(), -300, :second)

      {:ok, _} =
        DelayEvent.create(Map.merge(@valid_attrs, %{vehicle_id: "V/1/1", started_at: started_at}))

      {:ok, _} =
        DelayEvent.create(Map.merge(@valid_attrs, %{vehicle_id: "V/2/2", started_at: started_at}))

      {:ok, _} =
        DelayEvent.create(Map.merge(@valid_attrs, %{vehicle_id: "V/3/3", started_at: started_at}))

      # Verify they're unresolved
      assert length(DelayEvent.active()) == 3

      # Resolve orphaned
      {:ok, count} = DelayEvent.resolve_orphaned()

      assert count == 3
      assert DelayEvent.active() == []
    end

    test "sets correct duration for orphaned events" do
      started_at = DateTime.add(DateTime.utc_now(), -120, :second)

      {:ok, _} =
        DelayEvent.create(Map.merge(@valid_attrs, %{vehicle_id: "V/1/1", started_at: started_at}))

      {:ok, _count} = DelayEvent.resolve_orphaned()

      # Check the resolved event
      [event] = DelayEvent.recent(1)
      assert event.duration_seconds >= 119
      assert event.duration_seconds <= 125
    end

    test "does not affect already resolved events" do
      # Create and resolve a delay
      {:ok, event} = DelayEvent.create(@valid_attrs)
      {:ok, resolved} = DelayEvent.resolve(event)
      original_resolved_at = resolved.resolved_at

      # Call resolve_orphaned
      {:ok, count} = DelayEvent.resolve_orphaned()

      assert count == 0

      # Verify the original resolved_at is unchanged
      [event] = DelayEvent.recent(1)
      assert DateTime.compare(event.resolved_at, original_resolved_at) == :eq
    end

    test "returns 0 when no orphaned events" do
      {:ok, count} = DelayEvent.resolve_orphaned()
      assert count == 0
    end
  end
end
