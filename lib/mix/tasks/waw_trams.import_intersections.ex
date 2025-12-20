defmodule Mix.Tasks.WawTrams.ImportIntersections do
  @moduledoc """
  Imports tram-road intersection points from a CSV file into the database.

  The CSV file should be located at `priv/data/intersections.csv` with the format:
      "osm_id",lon,lat,"Street Name / Cross Street"

  No header row is expected. The name field contains street names from OSM.

  ## Usage

      mix waw_trams.import_intersections

  ## Options

      --file PATH  Path to CSV file (default: priv/data/intersections.csv)
  """

  use Mix.Task
  require Logger

  @shortdoc "Import intersection data from CSV into PostGIS"

  @default_file "priv/data/intersections.csv"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [file: :string])
    file_path = Keyword.get(opts, :file, @default_file)

    # Start the application to get Repo
    Mix.Task.run("app.start")

    case import_intersections(file_path) do
      {:ok, count} ->
        Mix.shell().info("Successfully imported #{count} intersections")

      {:error, reason} ->
        Mix.shell().error("Failed to import: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  defp import_intersections(file_path) do
    unless File.exists?(file_path) do
      {:error, "File not found: #{file_path}"}
    else
      do_import(file_path)
    end
  end

  defp do_import(file_path) do
    alias WawTrams.Repo

    file_path
    |> File.stream!([], :line)
    |> Stream.map(fn line ->
      # Ensure proper UTF-8 handling
      line
      |> :unicode.characters_to_binary(:utf8)
      |> parse_line()
    end)
    |> Stream.reject(&is_nil/1)
    |> Stream.chunk_every(500)
    |> Enum.reduce({:ok, 0}, fn batch, {:ok, total} ->
      case insert_batch(batch, Repo) do
        {:ok, count} -> {:ok, total + count}
        error -> error
      end
    end)
  end

  defp parse_line(line) do
    # CSV format: "osm_id",lon,lat,"name"
    # Split carefully to handle quoted name field with special chars
    line = String.trim(line)

    # First, extract osm_id (first quoted field)
    case Regex.run(~r/^"([^"]+)",(.+)$/, line) do
      [_, osm_id, rest] ->
        # Now split the rest: lon,lat,"name" or lon,lat,""
        parts = String.split(rest, ",", parts: 3)

        case parts do
          [lon, lat, name] ->
            # Remove surrounding quotes from name
            name = name |> String.trim("\"")
            parse_fields(osm_id, lon, lat, name)

          [lon, lat] ->
            parse_fields(osm_id, lon, lat, "")

          _ ->
            Logger.warning("Skipping malformed line: #{line}")
            nil
        end

      nil ->
        Logger.warning("Skipping malformed line (no osm_id): #{line}")
        nil
    end
  end

  defp parse_fields(osm_id, lon, lat, name) do
    with {lon_f, ""} <- Float.parse(lon),
         {lat_f, ""} <- Float.parse(lat) do
      %{osm_id: osm_id, lon: lon_f, lat: lat_f, name: name || ""}
    else
      _ ->
        Logger.warning("Skipping invalid coordinates: #{lon}, #{lat}")
        nil
    end
  end

  defp insert_batch(rows, repo) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    values =
      rows
      |> Enum.map(fn %{osm_id: osm_id, lon: lon, lat: lat, name: name} ->
        name_sql = if name && name != "", do: escape_string(name), else: "NULL"

        "(#{escape_string(osm_id)}, #{name_sql}, ST_SetSRID(ST_MakePoint(#{lon}, #{lat}), 4326), '#{now}', '#{now}')"
      end)
      |> Enum.join(", ")

    query = """
    INSERT INTO intersections (osm_id, name, geom, inserted_at, updated_at)
    VALUES #{values}
    ON CONFLICT (osm_id) DO UPDATE SET name = EXCLUDED.name, updated_at = EXCLUDED.updated_at
    """

    case repo.query(query) do
      {:ok, %{num_rows: count}} -> {:ok, count}
      {:error, reason} -> {:error, reason}
    end
  end

  defp escape_string(str) do
    escaped = String.replace(str, "'", "''")
    "'#{escaped}'"
  end
end
