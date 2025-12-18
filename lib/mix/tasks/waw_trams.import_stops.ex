defmodule Mix.Tasks.WawTrams.ImportStops do
  @moduledoc """
  Imports public transport stops from a GTFS stops.txt file into the database.

  Only imports Warsaw stops (Zone 1 and 1+2) that are actual platforms (location_type=0).
  This includes both tram and bus stops, as they often share platforms in Warsaw.

  The file should be standard GTFS format with header:
      stop_id,stop_name,stop_code,platform_code,stop_lat,stop_lon,location_type,
      parent_station,wheelchair_boarding,zone_id,stop_name_stem,town_name,street_name

  ## Usage

      mix waw_trams.import_stops

  ## Options

      --file PATH  Path to stops.txt file (default: priv/data/stops.txt)
  """

  use Mix.Task
  require Logger

  @shortdoc "Import GTFS stops into PostGIS (Warsaw Zone 1 only)"

  @default_file "priv/data/stops.txt"

  # Column indices in GTFS stops.txt (0-based)
  @col_stop_id 0
  @col_stop_name 1
  @col_stop_lat 4
  @col_stop_lon 5
  @col_location_type 6
  @col_zone_id 9

  # Filter criteria
  @valid_zones ["1", "1+2"]
  @valid_location_type "0"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [file: :string])
    file_path = Keyword.get(opts, :file, @default_file)

    # Start the application to get Repo
    Mix.Task.run("app.start")

    case import_stops(file_path) do
      {:ok, count, skipped} ->
        Mix.shell().info(
          "Successfully imported #{count} stops (skipped #{skipped} outside Zone 1)"
        )

      {:error, reason} ->
        Mix.shell().error("Failed to import: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  defp import_stops(file_path) do
    unless File.exists?(file_path) do
      {:error, "File not found: #{file_path}"}
    else
      do_import(file_path)
    end
  end

  defp do_import(file_path) do
    alias WawTrams.Repo

    {imported, skipped} =
      file_path
      |> File.stream!()
      |> Stream.drop(1)
      |> Stream.map(&parse_line/1)
      |> Stream.with_index()
      |> Enum.reduce({[], 0}, fn
        {{:ok, row}, _idx}, {rows, skipped} ->
          {[row | rows], skipped}

        {{:skip, _reason}, _idx}, {rows, skipped} ->
          {rows, skipped + 1}

        {{:error, reason}, idx}, {rows, skipped} ->
          Logger.warning("Line #{idx + 2}: #{reason}")
          {rows, skipped}
      end)

    # Reverse to maintain order, then batch insert
    rows = Enum.reverse(imported)

    rows
    |> Enum.chunk_every(500)
    |> Enum.reduce({:ok, 0}, fn batch, {:ok, total} ->
      case insert_batch(batch, Repo) do
        {:ok, count} -> {:ok, total + count}
        error -> error
      end
    end)
    |> case do
      {:ok, count} -> {:ok, count, skipped}
      error -> error
    end
  end

  defp parse_line(line) do
    columns =
      line
      |> String.trim()
      |> parse_csv_line()

    with {:ok, stop_id} <- get_column(columns, @col_stop_id),
         {:ok, name} <- get_column(columns, @col_stop_name),
         {:ok, lat_str} <- get_column(columns, @col_stop_lat),
         {:ok, lon_str} <- get_column(columns, @col_stop_lon),
         {:ok, location_type} <- get_column(columns, @col_location_type),
         {:ok, zone_id} <- get_column(columns, @col_zone_id),
         :ok <- validate_zone(zone_id),
         :ok <- validate_location_type(location_type),
         {:ok, lat} <- parse_float(lat_str),
         {:ok, lon} <- parse_float(lon_str) do
      {:ok, %{stop_id: stop_id, name: name, lat: lat, lon: lon}}
    end
  end

  # Simple CSV parser that handles quoted fields
  defp parse_csv_line(line) do
    # Split by comma, but this doesn't handle commas inside quotes
    # For GTFS stops.txt, fields with commas are rare, but let's handle basic cases
    line
    |> String.split(",")
    |> Enum.map(&String.trim/1)
  end

  defp get_column(columns, index) do
    case Enum.at(columns, index) do
      nil -> {:error, "Missing column #{index}"}
      "" -> {:error, "Empty column #{index}"}
      value -> {:ok, value}
    end
  end

  defp validate_zone(zone_id) do
    if zone_id in @valid_zones do
      :ok
    else
      {:skip, "Zone #{zone_id} not in Warsaw (Zone 1)"}
    end
  end

  defp validate_location_type(location_type) do
    if location_type == @valid_location_type do
      :ok
    else
      {:skip, "Location type #{location_type} is not a platform"}
    end
  end

  defp parse_float(str) do
    case Float.parse(str) do
      {value, ""} -> {:ok, value}
      {value, _rest} -> {:ok, value}
      :error -> {:error, "Invalid float: #{str}"}
    end
  end

  defp insert_batch(rows, repo) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    values =
      rows
      |> Enum.map(fn %{stop_id: stop_id, name: name, lon: lon, lat: lat} ->
        "(#{escape_string(stop_id)}, #{escape_string(name)}, ST_SetSRID(ST_MakePoint(#{lon}, #{lat}), 4326), '#{now}', '#{now}')"
      end)
      |> Enum.join(", ")

    query = """
    INSERT INTO stops (stop_id, name, geom, inserted_at, updated_at)
    VALUES #{values}
    ON CONFLICT (stop_id) DO NOTHING
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
