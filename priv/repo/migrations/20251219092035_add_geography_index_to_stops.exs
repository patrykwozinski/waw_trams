defmodule WawTrams.Repo.Migrations.AddGeographyIndexToStops do
  use Ecto.Migration

  @moduledoc """
  Replaces geometry GiST indexes with geography GiST indexes on stops and intersections.

  Problem: ST_DWithin queries cast geom to geography, which prevents the
  existing geometry indexes from being used. This caused 121K+ sequential scans
  on stops and 78K+ on intersections.

  Solution: Create GiST index on (geom::geography) to match query pattern.

  Before: Seq Scan, ~9ms per query, full table scan
  After: Index Scan, ~0.1ms per query
  """

  def up do
    # Drop old geometry indexes (not used due to geography cast)
    execute "DROP INDEX IF EXISTS stops_geom_idx"
    execute "DROP INDEX IF EXISTS intersections_geom_idx"

    # Create geography indexes that match our query pattern
    execute """
    CREATE INDEX stops_geom_geography_idx
    ON stops
    USING GIST ((geom::geography))
    """

    execute """
    CREATE INDEX intersections_geom_geography_idx
    ON intersections
    USING GIST ((geom::geography))
    """
  end

  def down do
    execute "DROP INDEX IF EXISTS stops_geom_geography_idx"
    execute "DROP INDEX IF EXISTS intersections_geom_geography_idx"

    # Restore original geometry indexes
    execute "CREATE INDEX stops_geom_idx ON stops USING GIST (geom)"
    execute "CREATE INDEX intersections_geom_idx ON intersections USING GIST (geom)"
  end
end
