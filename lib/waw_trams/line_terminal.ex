defmodule WawTrams.LineTerminal do
  @moduledoc """
  Represents a terminal stop for a specific tram line.

  Some stops are terminals for certain lines but regular stops for others.
  For example, Pl. Narutowicza is a terminal for line 14 but line 15 passes through.

  This table is populated from GTFS data (routes.txt, trips.txt, stop_times.txt)
  by the `mix waw_trams.import_line_terminals` task.
  """

  use Ecto.Schema
  import Ecto.Query

  alias WawTrams.Repo

  schema "line_terminals" do
    field :line, :string
    field :stop_id, :string
    field :terminal_name, :string
    field :direction, :string

    timestamps()
  end

  @doc """
  Checks if the given location is a terminal for the specified line.

  Uses spatial query to find stops within 50m of the coordinates,
  then checks if any of those stops are terminals for this line.

  Returns `true` if this is a terminal for the line, `false` otherwise.
  """
  @terminal_radius_meters 75

  def terminal_for_line?(line, lat, lon) when is_binary(line) do
    query = """
    SELECT EXISTS (
      SELECT 1
      FROM line_terminals lt
      JOIN stops s ON lt.stop_id = s.stop_id
      WHERE lt.line = $1
        AND ST_DWithin(
          s.geom::geography,
          ST_SetSRID(ST_MakePoint($2, $3), 4326)::geography,
          #{@terminal_radius_meters}
        )
    )
    """

    case Repo.query(query, [line, lon, lat]) do
      {:ok, %{rows: [[true]]}} -> true
      _ -> false
    end
  end

  def terminal_for_line?(_, _, _), do: false

  @doc """
  Returns all terminal stop_ids for a given line.
  """
  def terminals_for_line(line) do
    from(lt in __MODULE__, where: lt.line == ^line, select: lt.stop_id)
    |> Repo.all()
  end

  @doc """
  Returns all lines that have the given stop as a terminal.
  """
  def lines_with_terminal(stop_id) do
    from(lt in __MODULE__, where: lt.stop_id == ^stop_id, select: lt.line)
    |> Repo.all()
  end

  @doc """
  Inserts a line terminal record, ignoring duplicates.
  """
  def upsert!(attrs) do
    %__MODULE__{}
    |> Ecto.Changeset.cast(attrs, [:line, :stop_id, :terminal_name, :direction])
    |> Ecto.Changeset.validate_required([:line, :stop_id])
    |> Repo.insert!(on_conflict: :nothing, conflict_target: [:line, :stop_id])
  end

  @doc """
  Returns the count of line terminals in the database.
  """
  def count do
    Repo.one(from lt in __MODULE__, select: count(lt.id))
  end
end
