# Data Sources & Ingestion

> **Audience:** Operators setting up or refreshing data

This project relies on external data sources for spatial analysis:

| Source | Data | Update Frequency |
|--------|------|------------------|
| mkuran.pl GTFS | Stop locations | Weekly (download fresh) |
| OpenStreetMap | Tram-road intersections | Rarely (committed to repo) |
| ZTM API | Real-time tram positions | Every 10s (runtime) |

## 1. Stops (GTFS)

Warsaw stop locations from the community-maintained GTFS feed by [mkuran.pl](https://mkuran.pl/gtfs/).

> **Why mkuran.pl?** Cleaner than the raw ZTM FTP — deduplicated, validated, and actively maintained by a well-known member of the Warsaw transit community.

### Import (Auto-Download)

```bash
# Auto-downloads GTFS and imports (filters to Warsaw Zone 1 only)
mix waw_trams.import_stops
```

The task automatically:
1. Downloads GTFS from mkuran.pl (if not already cached)
2. Extracts to `/tmp/waw_trams_gtfs/`
3. Imports Zone 1 platforms into PostGIS

**Options:**
```bash
# Use existing GTFS directory
mix waw_trams.import_stops --dir /tmp/waw_trams_gtfs

# Use specific file
mix waw_trams.import_stops --file /path/to/stops.txt
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

## 2. Line Terminals (GTFS)

Line-specific terminal stops extracted from GTFS trip data. Used to skip delay detection at terminals (where trams normally wait between trips).

> **Why line-specific?** A stop like Pl. Narutowicza is a terminal for line 25 but a regular stop for line 15. Using GTFS trip data gives precise terminal mappings.

### Import

```bash
# Downloads GTFS and extracts first/last stops per trip
mix waw_trams.import_line_terminals

# Preview only (no database changes)
mix waw_trams.import_line_terminals --dry-run

# Use existing GTFS directory
mix waw_trams.import_line_terminals --dir /tmp/waw_trams_gtfs
```

This yields ~172 unique (line, stop_id) pairs from the GTFS data.

---

## 3. Intersections (OpenStreetMap)

Tram-road intersection points from OpenStreetMap via Overpass API, enriched with street names.

> **Why commit to repo?** Unlike GTFS, intersection data changes rarely (new tram lines are infrequent). The CSV is small (~1,200 rows) and acts as static seed data.

### CSV Format

```csv
"osm_id",lon,lat,"Street Name / Cross Street"
"node/32320979",21.0208934,52.2109083,"Puławska / Goworka"
```

The `name` field contains OSM street names for display (e.g., "Puławska / Goworka" instead of just a stop name). ~92% of intersections have street names; the rest fall back to nearest stop name.

### Overpass Queries

**1. Get intersection points:**

```c
[out:json][timeout:180][bbox:52.09, 20.85, 52.37, 21.28];

// Get Tram Tracks
way["railway"="tram"]->.trams;

// Get Car Roads (excluding pedestrian paths)
way["highway"]["highway"!~"^(footway|cycleway|path|steps|service)$"]->.roads;

// Find Intersections (Nodes shared by both)
node(w.trams)(w.roads);

out geom;
```

**2. Get road names for enrichment:**

```c
[out:json][timeout:180][bbox:52.09, 20.85, 52.37, 21.28];

way["railway"="tram"]->.trams;
way["highway"]["highway"!~"^(footway|cycleway|path|steps|service)$"]["name"]->.roads;
node(w.trams)(w.roads)->.intersections;
way(bn.intersections)["highway"]["name"];

out tags geom;
```

### Import Process

The CSV file `priv/data/intersections.csv` contains intersection nodes enriched with street names:

```csv
"osm_id",lon,lat,"name"
"node/32320979",21.0208934,52.2109083,"Puławska / Goworka"
"node/12345678",21.0123456,52.2234567,"Targowa"
```

**Steps to update intersection data:**

1. Run Overpass query to get intersection nodes
2. Run Overpass query to get road names for those nodes
3. Export both as GeoJSON
4. Run enrichment script:
   ```bash
   elixir scripts/enrich_intersections.exs
   ```
5. Import to database:
   ```bash
   mix waw_trams.import_intersections
   ```

The import is idempotent - it updates existing records and adds new ones.

**Coverage:** ~92% of intersections have street names (e.g., "Puławska / Goworka"). The remaining ~8% show only the primary street name or fall back to nearest tram stop name in the UI.
