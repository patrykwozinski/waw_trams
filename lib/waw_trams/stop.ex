defmodule WawTrams.Stop do
  @moduledoc """
  Represents a public transport stop in Warsaw (Zone 1).

  Used to determine if a tram is at a legitimate stop (passenger boarding)
  versus stuck at an intersection or in traffic.
  """

  use Ecto.Schema

  alias WawTrams.Repo

  schema "stops" do
    field :stop_id, :string
    field :name, :string
    # geom is a PostGIS geometry column, handled via raw SQL
    field :geom, :map, load_in_query: false

    timestamps(type: :utc_datetime)
  end

  @doc """
  Checks if a given lat/lon is within `radius_meters` of any stop.
  Returns true if near a stop, false otherwise.

  Used to filter out "false positive" delays — a tram stopped near
  a platform is likely picking up passengers, not stuck in traffic.
  """
  def near_stop?(lat, lon, radius_meters \\ 50) do
    query = """
    SELECT EXISTS(
      SELECT 1 FROM stops
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
  Returns the count of stops in the database.
  """
  def count do
    Repo.aggregate(__MODULE__, :count)
  end
end

