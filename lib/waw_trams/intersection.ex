defmodule WawTrams.Intersection do
  @moduledoc """
  Represents a tram-road intersection point from OpenStreetMap.

  These are locations where tram tracks cross car roads, typically
  controlled by traffic lights. Used to classify delays as "light" delays.
  """

  use Ecto.Schema

  alias WawTrams.Repo

  schema "intersections" do
    field :osm_id, :string
    field :name, :string
    # geom is a PostGIS geometry column, handled via raw SQL
    field :geom, :map, load_in_query: false

    timestamps(type: :utc_datetime)
  end

  @doc """
  Checks if a given lat/lon is within `radius_meters` of any intersection.
  Returns true if near an intersection, false otherwise.
  """
  def near_intersection?(lat, lon, radius_meters \\ 50) do
    query = """
    SELECT EXISTS(
      SELECT 1 FROM intersections
      WHERE ST_DWithin(
        geom::geography,
        ST_SetSRID(ST_MakePoint($1, $2), 4326)::geography,
        $3
      )
    )
    """

    case Repo.query(query, [lon, lat, radius_meters]) do
      {:ok, %{rows: [[true]]}} -> true
      _ -> false
    end
  end

  @doc """
  Returns the name of the nearest intersection within `radius_meters`.
  Returns nil if no intersection is found or if intersection has no name.
  """
  def nearest_name(lat, lon, radius_meters \\ 100) do
    query = """
    SELECT name FROM intersections
    WHERE name IS NOT NULL AND name != ''
      AND ST_DWithin(
        geom::geography,
        ST_SetSRID(ST_MakePoint($1, $2), 4326)::geography,
        $3
      )
    ORDER BY geom::geography <-> ST_SetSRID(ST_MakePoint($1, $2), 4326)::geography
    LIMIT 1
    """

    case Repo.query(query, [lon, lat, radius_meters]) do
      {:ok, %{rows: [[name]]}} -> name
      _ -> nil
    end
  end

  @doc """
  Returns the count of intersections in the database.
  """
  def count do
    Repo.aggregate(__MODULE__, :count)
  end
end
