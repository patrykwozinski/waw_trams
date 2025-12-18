defmodule WawTrams.Repo.Migrations.CreateStops do
  use Ecto.Migration

  def up do
    create table(:stops) do
      add :stop_id, :string, null: false
      add :name, :string, null: false

      timestamps(type: :utc_datetime)
    end

    # Add PostGIS geometry column (Point, SRID 4326 = WGS84)
    execute("SELECT AddGeometryColumn('stops', 'geom', 4326, 'POINT', 2)")

    # Spatial index for fast proximity queries
    execute("CREATE INDEX stops_geom_idx ON stops USING GIST (geom)")

    create unique_index(:stops, [:stop_id])
  end

  def down do
    drop table(:stops)
  end
end
