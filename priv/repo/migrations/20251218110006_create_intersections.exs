defmodule WawTrams.Repo.Migrations.CreateIntersections do
  use Ecto.Migration

  def up do
    create table(:intersections) do
      add :osm_id, :string, null: false

      timestamps(type: :utc_datetime)
    end

    # Add PostGIS geometry column (Point, SRID 4326 = WGS84)
    execute("SELECT AddGeometryColumn('intersections', 'geom', 4326, 'POINT', 2)")

    # Spatial index for fast proximity queries
    execute("CREATE INDEX intersections_geom_idx ON intersections USING GIST (geom)")

    create unique_index(:intersections, [:osm_id])
  end

  def down do
    drop table(:intersections)
  end
end
