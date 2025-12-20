defmodule WawTrams.Seeder do
  @moduledoc """
  Seeds initial data for the application.

  Used by Release.seed/0 for production deployments.
  Idempotent - skips if data already exists.
  """

  require Logger
  import Ecto.Query
  alias WawTrams.Repo

  @doc """
  Seeds all initial data (intersections, stops, line_terminals).
  """
  def seed_all do
    Logger.info("🌱 Seeding initial data...")

    seed_intersections()
    seed_stops()
    seed_line_terminals()

    Logger.info("🌱 Seeding complete!")
  end

  @doc """
  Seeds intersections from priv/data/intersections.csv.
  """
  def seed_intersections do
    case Repo.aggregate(WawTrams.Intersection, :count) do
      0 ->
        Logger.info("  → Importing intersections from CSV...")
        file_path = Application.app_dir(:waw_trams, "priv/data/intersections.csv")

        case import_intersections_from_csv(file_path) do
          {:ok, count} -> Logger.info("  ✓ Imported #{count} intersections")
          {:error, reason} -> Logger.error("  ✗ Failed: #{inspect(reason)}")
        end

      count ->
        Logger.info("  ✓ Intersections already exist (#{count} records)")
    end
  end

  @doc """
  Seeds stops from GTFS feed.
  """
  def seed_stops do
    case Repo.aggregate(WawTrams.Stop, :count) do
      0 ->
        Logger.info("  → Importing stops from GTFS...")

        case import_stops_from_gtfs() do
          {:ok, count} -> Logger.info("  ✓ Imported #{count} stops")
          {:error, reason} -> Logger.error("  ✗ Failed: #{inspect(reason)}")
        end

      count ->
        Logger.info("  ✓ Stops already exist (#{count} records)")
    end
  end

  @doc """
  Seeds line terminals from GTFS feed.
  """
  def seed_line_terminals do
    case Repo.aggregate(WawTrams.LineTerminal, :count) do
      0 ->
        Logger.info("  → Importing line terminals from GTFS...")

        case import_line_terminals_from_gtfs() do
          {:ok, count} -> Logger.info("  ✓ Imported #{count} line terminals")
          {:error, reason} -> Logger.error("  ✗ Failed: #{inspect(reason)}")
        end

      count ->
        Logger.info("  ✓ Line terminals already exist (#{count} records)")
    end
  end

  # --- Intersections (from CSV) ---

  defp import_intersections_from_csv(file_path) do
    unless File.exists?(file_path) do
      {:error, "File not found: #{file_path}"}
    else
      file_path
      |> File.stream!([], :line)
      |> Stream.map(fn line ->
        line
        |> :unicode.characters_to_binary(:utf8)
        |> parse_intersection_line()
      end)
      |> Stream.reject(&is_nil/1)
      |> Stream.chunk_every(500)
      |> Enum.reduce({:ok, 0}, fn batch, {:ok, total} ->
        case insert_intersection_batch(batch) do
          {:ok, count} -> {:ok, total + count}
          error -> error
        end
      end)
    end
  end

  defp parse_intersection_line(line) do
    line = String.trim(line)

    case Regex.run(~r/^"([^"]+)",(.+)$/, line) do
      [_, osm_id, rest] ->
        parts = String.split(rest, ",", parts: 3)

        case parts do
          [lon, lat, name] ->
            parse_intersection_fields(osm_id, lon, lat, String.trim(name, "\""))

          [lon, lat] ->
            parse_intersection_fields(osm_id, lon, lat, "")

          _ ->
            nil
        end

      _ ->
        nil
    end
  end

  defp parse_intersection_fields(osm_id, lon, lat, name) do
    with {lon_f, ""} <- Float.parse(lon),
         {lat_f, ""} <- Float.parse(lat) do
      %{osm_id: osm_id, lon: lon_f, lat: lat_f, name: name || ""}
    else
      _ -> nil
    end
  end

  defp insert_intersection_batch(rows) do
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

    case Repo.query(query) do
      {:ok, %{num_rows: count}} -> {:ok, count}
      {:error, reason} -> {:error, reason}
    end
  end

  # --- GTFS Download ---

  @gtfs_url "https://mkuran.pl/gtfs/warsaw.zip"
  @gtfs_dir "/tmp/waw_trams_gtfs_seed"

  defp ensure_gtfs_downloaded do
    if File.exists?(Path.join(@gtfs_dir, "stops.txt")) do
      :ok
    else
      download_gtfs()
    end
  end

  defp download_gtfs do
    Logger.info("  📥 Downloading GTFS from #{@gtfs_url}...")

    zip_path = Path.join(System.tmp_dir!(), "warsaw_gtfs_seed.zip")

    case Req.get(@gtfs_url, into: File.stream!(zip_path)) do
      {:ok, %{status: 200}} ->
        Logger.info("  📦 Extracting GTFS...")
        File.mkdir_p!(@gtfs_dir)
        {:ok, _} = :zip.unzip(String.to_charlist(zip_path), cwd: String.to_charlist(@gtfs_dir))
        File.rm(zip_path)
        :ok

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # --- Stops (from GTFS) ---

  defp import_stops_from_gtfs do
    with :ok <- ensure_gtfs_downloaded() do
      stops_file = Path.join(@gtfs_dir, "stops.txt")
      import_stops_from_file(stops_file)
    end
  end

  defp import_stops_from_file(file_path) do
    rows =
      file_path
      |> File.stream!()
      |> Stream.drop(1)
      |> Stream.map(&parse_gtfs_stop_line/1)
      |> Enum.reject(&is_nil/1)

    insert_stops(rows)
  end

  defp parse_gtfs_stop_line(line) do
    # Column indices in GTFS stops.txt
    cols = line |> String.trim() |> String.split(",") |> Enum.map(&String.trim/1)

    stop_id = Enum.at(cols, 0)
    name = Enum.at(cols, 1)
    lat_str = Enum.at(cols, 4)
    lon_str = Enum.at(cols, 5)
    location_type = Enum.at(cols, 6)
    zone = Enum.at(cols, 9)

    # Only import platforms (location_type=0) in Zone 1
    if stop_id && name && lat_str && lon_str &&
         location_type == "0" && zone in ["1", "1+2"] do
      case {Float.parse(lat_str), Float.parse(lon_str)} do
        {{lat, _}, {lon, _}} ->
          %{stop_id: stop_id, name: name, lat: lat, lon: lon}

        _ ->
          nil
      end
    else
      nil
    end
  end

  defp insert_stops(stops) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    stops
    |> Enum.chunk_every(500)
    |> Enum.reduce({:ok, 0}, fn batch, {:ok, total} ->
      values =
        batch
        |> Enum.map(fn %{stop_id: id, name: name, lat: lat, lon: lon} ->
          "(#{escape_string(id)}, #{escape_string(name)}, ST_SetSRID(ST_MakePoint(#{lon}, #{lat}), 4326), false, '#{now}', '#{now}')"
        end)
        |> Enum.join(", ")

      query = """
      INSERT INTO stops (stop_id, name, geom, is_terminal, inserted_at, updated_at)
      VALUES #{values}
      ON CONFLICT (stop_id) DO UPDATE SET name = EXCLUDED.name, updated_at = EXCLUDED.updated_at
      """

      case Repo.query(query) do
        {:ok, %{num_rows: count}} -> {:ok, total + count}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  # --- Line Terminals (from GTFS) ---

  defp import_line_terminals_from_gtfs do
    with :ok <- ensure_gtfs_downloaded() do
      trips_file = Path.join(@gtfs_dir, "trips.txt")
      stop_times_file = Path.join(@gtfs_dir, "stop_times.txt")

      with {:ok, trips} <- parse_trips_file(trips_file),
           {:ok, stop_times} <- parse_stop_times_file(stop_times_file) do
        terminals = extract_terminals(trips, stop_times)
        insert_terminals(terminals)
      end
    end
  end

  defp parse_trips_file(file_path) do
    # Format: trip_id,route_id,service_id,...
    trips =
      file_path
      |> File.stream!()
      |> Stream.drop(1)
      |> Stream.map(fn line ->
        case line |> String.trim() |> String.split(",") do
          [trip_id, route_id | _] ->
            # route_id is the line number (e.g., "1", "10", "102")
            {trip_id, route_id}

          _ ->
            nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Map.new()

    {:ok, trips}
  end

  defp parse_stop_times_file(file_path) do
    # Format: trip_id,stop_sequence,stop_id,arrival_time,departure_time,...
    stop_times =
      file_path
      |> File.stream!()
      |> Stream.drop(1)
      |> Stream.map(fn line ->
        case line |> String.trim() |> String.split(",") do
          [trip_id, seq, stop_id | _] ->
            case Integer.parse(seq) do
              {seq_int, _} -> {trip_id, stop_id, seq_int}
              :error -> nil
            end

          _ ->
            nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    {:ok, stop_times}
  end

  defp extract_terminals(trips, stop_times) do
    # Group stop_times by trip and find first/last stops
    stop_times
    |> Enum.group_by(fn {trip_id, _, _} -> trip_id end)
    |> Enum.flat_map(fn {trip_id, times} ->
      line = Map.get(trips, trip_id)

      if line && tram_line?(line) do
        sorted = Enum.sort_by(times, fn {_, _, seq} -> seq end)
        first = sorted |> List.first() |> elem(1)
        last = sorted |> List.last() |> elem(1)
        [{line, first}, {line, last}]
      else
        []
      end
    end)
    |> Enum.uniq()
    |> Enum.filter(fn {line, sid} ->
      # Only include if stop exists and is a tram line
      tram_line?(line) and stop_exists?(sid)
    end)
  end

  defp tram_line?(line) do
    case Integer.parse(line) do
      {n, ""} when n >= 1 and n <= 79 -> true
      _ -> false
    end
  end

  defp stop_exists?(stop_id) do
    Repo.exists?(from s in WawTrams.Stop, where: s.stop_id == ^stop_id)
  end

  defp insert_terminals(terminals) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    terminals
    |> Enum.chunk_every(100)
    |> Enum.reduce({:ok, 0}, fn batch, {:ok, total} ->
      values =
        batch
        |> Enum.map(fn {line, stop_id} ->
          "(#{escape_string(line)}, #{escape_string(stop_id)}, '#{now}', '#{now}')"
        end)
        |> Enum.join(", ")

      query = """
      INSERT INTO line_terminals (line, stop_id, inserted_at, updated_at)
      VALUES #{values}
      ON CONFLICT (line, stop_id) DO NOTHING
      """

      case Repo.query(query) do
        {:ok, %{num_rows: count}} -> {:ok, total + count}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  # Also mark stops as terminals
  def mark_terminal_stops do
    Repo.update_all(
      from(s in WawTrams.Stop,
        where:
          s.stop_id in subquery(
            from(lt in WawTrams.LineTerminal, select: lt.stop_id, distinct: true)
          )
      ),
      set: [is_terminal: true]
    )
  end

  defp escape_string(str) do
    escaped = String.replace(to_string(str), "'", "''")
    "'#{escaped}'"
  end
end
