defmodule Mix.Tasks.WawTrams.ImportIntersections do
  @moduledoc """
  Imports tram-road intersection points from a CSV file into the database.

  The CSV file should be located at `priv/data/intersections.csv` with the format:
      osm_id,lon,lat

  No header row is expected.

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
    |> File.stream!()
    |> Stream.map(&parse_line/1)
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
    line
    |> String.trim()
    |> String.split(",")
    |> case do
      [osm_id, lon, lat] ->
        # Remove quotes from osm_id if present
        osm_id = String.trim(osm_id, "\"")

        with {lon_f, ""} <- Float.parse(lon),
             {lat_f, ""} <- Float.parse(lat) do
          %{osm_id: osm_id, lon: lon_f, lat: lat_f}
        else
          _ ->
            Logger.warning("Skipping invalid line: #{line}")
            nil
        end

      _ ->
        Logger.warning("Skipping malformed line: #{line}")
        nil
    end
  end

  defp insert_batch(rows, repo) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    values =
      rows
      |> Enum.map(fn %{osm_id: osm_id, lon: lon, lat: lat} ->
        "(#{escape_string(osm_id)}, ST_SetSRID(ST_MakePoint(#{lon}, #{lat}), 4326), '#{now}', '#{now}')"
      end)
      |> Enum.join(", ")

    query = """
    INSERT INTO intersections (osm_id, geom, inserted_at, updated_at)
    VALUES #{values}
    ON CONFLICT (osm_id) DO NOTHING
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
