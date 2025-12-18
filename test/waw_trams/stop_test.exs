defmodule WawTrams.StopTest do
  use WawTrams.DataCase, async: true

  alias WawTrams.Stop

  describe "near_stop?/3" do
    test "returns true when point is within radius of a stop" do
      insert_stop!("100101", "Kijowska", 21.044827, 52.248455)

      # Same location - should be near
      assert Stop.near_stop?(52.248455, 21.044827, 50) == true
    end

    test "returns false when point is outside radius of any stop" do
      insert_stop!("100101", "Kijowska", 21.044827, 52.248455)

      # ~1km away - should not be near
      assert Stop.near_stop?(52.258, 21.044827, 50) == false
    end

    test "returns false when no stops exist" do
      assert Stop.near_stop?(52.248455, 21.044827, 50) == false
    end

    test "respects custom radius" do
      insert_stop!("100101", "Kijowska", 21.044827, 52.248455)

      # Point ~100m away
      lat = 52.2494
      lon = 21.044827

      # Should be outside 50m radius
      assert Stop.near_stop?(lat, lon, 50) == false

      # Should be inside 200m radius
      assert Stop.near_stop?(lat, lon, 200) == true
    end

    test "handles multiple stops" do
      insert_stop!("100101", "Kijowska", 21.044827, 52.248455)
      insert_stop!("100201", "Ząbkowska", 21.038457, 52.251325)
      insert_stop!("100301", "Dw. Wileński", 21.035454, 52.253739)

      # Near first stop
      assert Stop.near_stop?(52.248455, 21.044827, 50) == true

      # Near second stop
      assert Stop.near_stop?(52.251325, 21.038457, 50) == true

      # Not near any
      assert Stop.near_stop?(52.0, 21.0, 50) == false
    end
  end

  describe "count/0" do
    test "returns 0 when no stops" do
      assert Stop.count() == 0
    end

    test "returns correct count" do
      insert_stop!("100101", "Kijowska", 21.044827, 52.248455)
      insert_stop!("100102", "Kijowska", 21.044443, 52.249078)

      assert Stop.count() == 2
    end
  end

  # Helper to insert stop with PostGIS geometry
  defp insert_stop!(stop_id, name, lon, lat) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.query!(
      """
      INSERT INTO stops (stop_id, name, geom, inserted_at, updated_at)
      VALUES ($1, $2, ST_SetSRID(ST_MakePoint($3, $4), 4326), $5, $6)
      """,
      [stop_id, name, lon, lat, now, now]
    )
  end
end

