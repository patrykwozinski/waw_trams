#!/usr/bin/env elixir
# Script to enrich intersection CSV with street names from road GeoJSON
#
# Usage:
#   elixir scripts/enrich_intersections.exs \
#     --roads /path/to/waw-intersections.geojson \
#     --intersections priv/data/intersections.csv \
#     --output priv/data/intersections_enriched.csv

Mix.install([{:jason, "~> 1.4"}])

defmodule IntersectionEnricher do
  @doc """
  Finds street names for each intersection point by checking
  which road geometries pass near that point.
  """

  # Distance threshold in degrees (~30m at Warsaw's latitude)
  @distance_threshold 0.0003

  def run(roads_file, intersections_file, output_file) do
    IO.puts("Loading roads from GeoJSON...")
    roads = load_roads(roads_file)
    IO.puts("Loaded #{length(roads)} roads with names")

    IO.puts("\nLoading intersection points...")
    intersections = load_intersections(intersections_file)
    IO.puts("Loaded #{length(intersections)} intersections")

    IO.puts("\nMatching intersections to street names...")
    enriched = enrich_intersections(intersections, roads)

    IO.puts("\nWriting enriched CSV...")
    write_csv(enriched, output_file)

    # Stats
    with_names = Enum.count(enriched, fn {_, _, _, names} -> length(names) >= 2 end)
    IO.puts("\n✅ Done! #{with_names}/#{length(enriched)} intersections have 2+ street names")
  end

  defp load_roads(file) do
    file
    |> File.read!()
    |> Jason.decode!()
    |> Map.get("features")
    |> Enum.filter(fn f -> f["properties"]["name"] end)
    |> Enum.map(fn f ->
      name = f["properties"]["name"]
      coords = f["geometry"]["coordinates"]
      {name, coords}
    end)
  end

  defp load_intersections(file) do
    file
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      # Format: "node/123",21.0,52.2
      [id, lon, lat] = String.split(line, ",")
      id = String.trim(id, "\"")
      {id, String.to_float(lon), String.to_float(lat)}
    end)
  end

  defp enrich_intersections(intersections, roads) do
    total = length(intersections)

    intersections
    |> Enum.with_index(1)
    |> Enum.map(fn {{id, lon, lat}, idx} ->
      if rem(idx, 100) == 0, do: IO.write("\r  Processing #{idx}/#{total}...")

      names = find_street_names(lon, lat, roads)
      {id, lon, lat, names}
    end)
    |> tap(fn _ -> IO.puts("\r  Processing #{total}/#{total}... done!") end)
  end

  defp find_street_names(lon, lat, roads) do
    roads
    |> Enum.filter(fn {_name, coords} ->
      point_near_linestring?(lon, lat, coords)
    end)
    |> Enum.map(fn {name, _} -> name end)
    |> Enum.uniq()
    |> Enum.take(3)  # Max 3 street names
  end

  defp point_near_linestring?(px, py, coords) do
    # Check if point is near any segment of the linestring
    coords
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.any?(fn [[x1, y1], [x2, y2]] ->
      point_near_segment?(px, py, x1, y1, x2, y2)
    end)
  end

  defp point_near_segment?(px, py, x1, y1, x2, y2) do
    # Distance from point to line segment
    dx = x2 - x1
    dy = y2 - y1
    len_sq = dx * dx + dy * dy

    if len_sq == 0 do
      # Segment is a point
      distance(px, py, x1, y1) < @distance_threshold
    else
      # Project point onto line, clamped to segment
      t = max(0, min(1, ((px - x1) * dx + (py - y1) * dy) / len_sq))
      proj_x = x1 + t * dx
      proj_y = y1 + t * dy
      distance(px, py, proj_x, proj_y) < @distance_threshold
    end
  end

  defp distance(x1, y1, x2, y2) do
    :math.sqrt((x2 - x1) * (x2 - x1) + (y2 - y1) * (y2 - y1))
  end

  defp write_csv(enriched, output_file) do
    lines =
      Enum.map(enriched, fn {id, lon, lat, names} ->
        name_str = Enum.join(names, " / ")
        ~s("#{id}",#{lon},#{lat},"#{name_str}")
      end)

    File.write!(output_file, Enum.join(lines, "\n"))
  end
end

# Parse args
{opts, _, _} = OptionParser.parse(System.argv(), strict: [
  roads: :string,
  intersections: :string,
  output: :string
])

roads = opts[:roads] || raise "Missing --roads argument"
intersections = opts[:intersections] || raise "Missing --intersections argument"
output = opts[:output] || raise "Missing --output argument"

IntersectionEnricher.run(roads, intersections, output)
