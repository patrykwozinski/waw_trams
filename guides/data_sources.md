# Data Sources & Ingestion

This project relies on external data sources for spatial analysis:

| Source | Data | Update Frequency |
|--------|------|------------------|
| mkuran.pl GTFS | Stop locations | Weekly (download fresh) |
| OpenStreetMap | Tram-road intersections | Rarely (committed to repo) |
| ZTM API | Real-time tram positions | Every 10s (runtime) |

## 1. Stops (GTFS)

Warsaw stop locations from the community-maintained GTFS feed by [mkuran.pl](https://mkuran.pl/gtfs/).

> **Why mkuran.pl?** Cleaner than the raw ZTM FTP — deduplicated, validated, and actively maintained by a well-known member of the Warsaw transit community.

### Download & Import

```bash
# Download the latest Warsaw GTFS
wget https://mkuran.pl/gtfs/warsaw.zip -O /tmp/warsaw.zip

# Extract just stops.txt to priv/data/
unzip -j /tmp/warsaw.zip stops.txt -d priv/data/

# Import into PostGIS (filters to Warsaw Zone 1 only)
mix waw_trams.import_stops
```

### What Gets Imported

The importer filters the GTFS data:

| Filter | Value | Reason |
|--------|-------|--------|
| `zone_id` | `1` or `1+2` | Warsaw proper (Zone 2 has no trams) |
| `location_type` | `0` | Actual platforms, not stations or entrances |

This yields ~5,000 stops from the original ~7,000 in the file.

### Re-importing

The import is idempotent (`ON CONFLICT DO NOTHING`). To refresh data:

```bash
# Re-download and re-run
mix waw_trams.import_stops
```

To completely reset:

```bash
# In psql or via Ecto
TRUNCATE stops RESTART IDENTITY;
mix waw_trams.import_stops
```

---

## 2. Intersections (OpenStreetMap)

Tram-road intersection points from OpenStreetMap via Overpass API.

> **Why commit to repo?** Unlike GTFS, intersection data changes rarely (new tram lines are infrequent). The CSV is small (~1,200 rows) and acts as static seed data.

### The Query
To update the `intersections.csv` file, run this query at [Overpass Turbo](https://overpass-turbo.eu/).

```c
/* Goal: Find intersections between Tram Tracks and Car Roads in Warsaw.
  Target Area: Warsaw Bounding Box.
*/
[out:json][timeout:180][bbox:52.09, 20.85, 52.37, 21.28];

// 1. Get Tram Tracks
way["railway"="tram"]->.trams;

// 2. Get Car Roads (excluding pedestrian paths)
way["highway"]["highway"!~"^(footway|cycleway|path|steps|service)$"]->.roads;

// 3. Find Intersections (Nodes shared by both)
node(w.trams)(w.roads);

out geom;
```

### Import Process
1. Export the result as GeoJSON.
2. Convert to CSV using jq.
3. Run the mix task:
```sh
mix waw_trams.import_intersections
```
