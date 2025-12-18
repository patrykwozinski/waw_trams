defmodule Mix.Tasks.WawTrams.ImportLineTerminals do
  @moduledoc """
  Imports line-specific terminal stops from GTFS data.

  This task parses GTFS files to identify which stops are terminals (first/last)
  for each tram line. This allows proper detection of line-specific terminals
  (e.g., Pl. Narutowicza is terminal for line 14 but not for line 15).

  ## Usage

      # Download GTFS and import (recommended)
      mix waw_trams.import_line_terminals

      # Use existing GTFS files in a directory
      mix waw_trams.import_line_terminals --dir /path/to/gtfs

      # Preview without inserting
      mix waw_trams.import_line_terminals --dry-run

  ## GTFS Files Required

  - `routes.txt` - to identify tram lines (route_type = 0)
  - `trips.txt` - to get trips for each route
  - `stop_times.txt` - to find first/last stops of each trip
  - `stops.txt` - to get terminal names
  """

  use Mix.Task
  require Logger

  @shortdoc "Import line-specific terminals from GTFS"

  @gtfs_url "https://mkuran.pl/gtfs/warsaw.zip"
  @tmp_dir "/tmp/waw_trams_gtfs"

  # GTFS route_type for trams
  @tram_route_type "0"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [dir: :string, dry_run: :boolean])

    Mix.Task.run("app.start")

    gtfs_dir = Keyword.get(opts, :dir) || download_gtfs()
    dry_run = Keyword.get(opts, :dry_run, false)

    {:ok, count} = import_terminals(gtfs_dir, dry_run)

    if dry_run do
      Mix.shell().info("🔍 Dry run: would import #{count} line terminals")
    else
      Mix.shell().info("✅ Imported #{count} line terminals")
    end
  end

  defp download_gtfs do
    Mix.shell().info("📥 Downloading GTFS from #{@gtfs_url}...")

    File.rm_rf!(@tmp_dir)
    File.mkdir_p!(@tmp_dir)

    zip_path = Path.join(@tmp_dir, "warsaw.zip")

    case Req.get(@gtfs_url, into: File.stream!(zip_path)) do
      {:ok, _} ->
        Mix.shell().info("📦 Extracting GTFS files...")
        {:ok, _} = :zip.unzip(String.to_charlist(zip_path), cwd: String.to_charlist(@tmp_dir))
        @tmp_dir

      {:error, reason} ->
        Mix.raise("Failed to download GTFS: #{inspect(reason)}")
    end
  end

  defp import_terminals(gtfs_dir, dry_run) do
    Mix.shell().info("🔍 Parsing GTFS files...")

    # Step 1: Get tram route IDs
    tram_routes = parse_tram_routes(Path.join(gtfs_dir, "routes.txt"))
    Mix.shell().info("   Found #{map_size(tram_routes)} tram routes")

    # Step 2: Get trips for tram routes
    tram_trips = parse_tram_trips(Path.join(gtfs_dir, "trips.txt"), tram_routes)
    Mix.shell().info("   Found #{map_size(tram_trips)} tram trips")

    # Step 3: Get stop names
    stop_names = parse_stop_names(Path.join(gtfs_dir, "stops.txt"))
    Mix.shell().info("   Loaded #{map_size(stop_names)} stop names")

    # Step 4: Find terminal stops for each trip
    terminals = find_terminals(Path.join(gtfs_dir, "stop_times.txt"), tram_trips)
    Mix.shell().info("   Found #{length(terminals)} terminal records")

    # Step 5: Deduplicate and prepare for insert
    unique_terminals =
      terminals
      |> Enum.uniq_by(fn {line, stop_id, _dir} -> {line, stop_id} end)
      |> Enum.map(fn {line, stop_id, direction} ->
        %{
          line: line,
          stop_id: stop_id,
          terminal_name: Map.get(stop_names, stop_id, "Unknown"),
          direction: direction
        }
      end)

    Mix.shell().info("   #{length(unique_terminals)} unique (line, stop) pairs")

    if dry_run do
      # Show sample
      Mix.shell().info("\n📋 Sample terminals:")

      unique_terminals
      |> Enum.take(20)
      |> Enum.each(fn t ->
        Mix.shell().info("   Line #{t.line}: #{t.terminal_name} (#{t.stop_id}) [#{t.direction}]")
      end)

      {:ok, length(unique_terminals)}
    else
      # Clear existing and insert
      alias WawTrams.{Repo, LineTerminal}

      Repo.delete_all(LineTerminal)

      inserted =
        unique_terminals
        |> Enum.chunk_every(100)
        |> Enum.reduce(0, fn batch, acc ->
          now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

          entries =
            Enum.map(batch, fn attrs ->
              Map.merge(attrs, %{inserted_at: now, updated_at: now})
            end)

          {count, _} = Repo.insert_all(LineTerminal, entries, on_conflict: :nothing)
          acc + count
        end)

      {:ok, inserted}
    end
  end

  # Parse routes.txt and return map of route_id => line_number for trams
  defp parse_tram_routes(path) do
    path
    |> File.stream!()
    |> Stream.drop(1)
    |> Stream.map(&String.trim/1)
    |> Stream.map(&parse_csv_line/1)
    |> Stream.filter(fn cols -> Enum.at(cols, 4) == @tram_route_type end)
    |> Enum.reduce(%{}, fn cols, acc ->
      route_id = Enum.at(cols, 0)
      line = Enum.at(cols, 2)
      Map.put(acc, route_id, line)
    end)
  end

  # Parse trips.txt and return map of trip_id => line_number for tram trips
  defp parse_tram_trips(path, tram_routes) do
    path
    |> File.stream!()
    |> Stream.drop(1)
    |> Stream.map(&String.trim/1)
    |> Stream.map(&parse_csv_line/1)
    |> Stream.filter(fn cols ->
      route_id = Enum.at(cols, 1)
      Map.has_key?(tram_routes, route_id)
    end)
    |> Enum.reduce(%{}, fn cols, acc ->
      trip_id = Enum.at(cols, 0)
      route_id = Enum.at(cols, 1)
      line = Map.get(tram_routes, route_id)
      Map.put(acc, trip_id, line)
    end)
  end

  # Parse stops.txt and return map of stop_id => name
  defp parse_stop_names(path) do
    path
    |> File.stream!()
    |> Stream.drop(1)
    |> Stream.map(&String.trim/1)
    |> Stream.map(&parse_csv_line/1)
    |> Enum.reduce(%{}, fn cols, acc ->
      stop_id = Enum.at(cols, 0)
      name = Enum.at(cols, 1)
      Map.put(acc, stop_id, name)
    end)
  end

  # Parse stop_times.txt and find first/last stop for each trip
  # Returns list of {line, stop_id, direction}
  defp find_terminals(path, tram_trips) do
    # Group stop_times by trip_id, keeping only tram trips
    # Then find min/max stop_sequence for each trip

    Mix.shell().info("   Processing stop_times.txt (this may take a moment)...")

    # Stream through stop_times and collect first/last for each trip
    path
    |> File.stream!()
    |> Stream.drop(1)
    |> Stream.map(&String.trim/1)
    |> Stream.map(&parse_csv_line/1)
    |> Stream.filter(fn cols ->
      trip_id = Enum.at(cols, 0)
      Map.has_key?(tram_trips, trip_id)
    end)
    |> Enum.reduce(%{}, fn cols, acc ->
      trip_id = Enum.at(cols, 0)
      stop_seq = parse_int(Enum.at(cols, 1))
      stop_id = Enum.at(cols, 2)

      current = Map.get(acc, trip_id, %{min: {999_999, nil}, max: {-1, nil}})

      {min_seq, min_stop} = current.min
      {max_seq, max_stop} = current.max

      new_min = if stop_seq < min_seq, do: {stop_seq, stop_id}, else: {min_seq, min_stop}
      new_max = if stop_seq > max_seq, do: {stop_seq, stop_id}, else: {max_seq, max_stop}

      Map.put(acc, trip_id, %{min: new_min, max: new_max})
    end)
    |> Enum.flat_map(fn {trip_id, %{min: {_, start_stop}, max: {_, end_stop}}} ->
      line = Map.get(tram_trips, trip_id)

      terminals = []
      terminals = if start_stop, do: [{line, start_stop, "start"} | terminals], else: terminals
      terminals = if end_stop, do: [{line, end_stop, "end"} | terminals], else: terminals
      terminals
    end)
  end

  defp parse_csv_line(line) do
    # Simple CSV parser - handles basic quoting
    line
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.map(fn field ->
      field
      |> String.trim("\"")
      |> String.trim()
    end)
  end

  defp parse_int(str) do
    case Integer.parse(str) do
      {n, _} -> n
      :error -> 0
    end
  end
end
