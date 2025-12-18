defmodule WawTrams.IntersectionTest do
  use WawTrams.DataCase, async: true

  alias WawTrams.Intersection

  describe "near_intersection?/3" do
    test "returns true when point is within radius of an intersection" do
      insert_intersection!("node/123", 21.0, 52.25)

      # Same location - should be near
      assert Intersection.near_intersection?(52.25, 21.0, 50) == true
    end

    test "returns false when point is outside radius of any intersection" do
      insert_intersection!("node/123", 21.0, 52.25)

      # ~1km away - should not be near
      assert Intersection.near_intersection?(52.26, 21.0, 50) == false
    end

    test "returns false when no intersections exist" do
      assert Intersection.near_intersection?(52.25, 21.0, 50) == false
    end

    test "respects custom radius" do
      insert_intersection!("node/123", 21.0, 52.25)

      # Point ~100m away
      lat = 52.2509
      lon = 21.0

      # Should be outside 50m radius
      assert Intersection.near_intersection?(lat, lon, 50) == false

      # Should be inside 200m radius
      assert Intersection.near_intersection?(lat, lon, 200) == true
    end

    test "handles multiple intersections" do
      insert_intersection!("node/1", 21.0, 52.25)
      insert_intersection!("node/2", 21.1, 52.30)
      insert_intersection!("node/3", 20.9, 52.20)

      # Near first intersection
      assert Intersection.near_intersection?(52.25, 21.0, 50) == true

      # Near second intersection
      assert Intersection.near_intersection?(52.30, 21.1, 50) == true

      # Not near any
      assert Intersection.near_intersection?(52.0, 21.0, 50) == false
    end
  end

  describe "count/0" do
    test "returns 0 when no intersections" do
      assert Intersection.count() == 0
    end

    test "returns correct count" do
      insert_intersection!("node/1", 21.0, 52.25)
      insert_intersection!("node/2", 21.1, 52.30)

      assert Intersection.count() == 2
    end
  end

  # Helper to insert intersection with PostGIS geometry
  defp insert_intersection!(osm_id, lon, lat) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.query!(
      """
      INSERT INTO intersections (osm_id, geom, inserted_at, updated_at)
      VALUES ($1, ST_SetSRID(ST_MakePoint($2, $3), 4326), $4, $5)
      """,
      [osm_id, lon, lat, now, now]
    )
  end
end
