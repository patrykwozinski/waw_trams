# Warsaw Tram Priority Auditor

Real-time detection and analysis of delays in the Warsaw tram network (ZTM), identifying inefficient traffic signal timing.

## Problem

Warsaw's tram network experiences delays from traffic light inefficiency, accidents, and normal boarding. **Goal:** Identify which intersections cause the most delays for transit priority advocacy.

## Key Insight

**57% of tram-road intersections have a stop within 50m.** This means we can't classify delays as "light" vs "boarding" in real-time. Instead:

1. Detect all unusual stops (time-based)
2. Persist to database with location
3. Analyze post-hoc which intersections accumulate the most delay

## Architecture

```
WawTrams.Application
└── Supervisor
    ├── Registry (TramRegistry)
    ├── Poller (GenServer) ─── fetches GTFS-RT every 10s
    └── TramSupervisor (DynamicSupervisor)
        └── TramWorker × ~300 ─── one process per active tram
                │
                └── DelayEvent ─── persisted to PostgreSQL
```

## Detection Logic

```
Tram stopped (speed < 3 km/h):

├── AT TERMINAL (pętla, zajezdnia, P+R)
│   └── SKIP ─── normal layover behavior
│
├── AT REGULAR STOP (within 50m)
│   ├── < 180s  → normal_dwell (ignore)
│   └── > 180s  → blockage (persist) ← something is wrong
│
└── NOT AT STOP
    └── > 30s   → delay (persist) ← traffic/signal issue!
```

**Only actionable delays are persisted** — `delay` events (not at stop) are the gold for identifying problematic intersections.

Example logs:
```
[DELAY] Vehicle V/17/5 (Line 17) stopped at (52.2297, 21.0122) - delay, at_stop: false, near_intersection: true
[RESOLVED] Vehicle V/17/5 (Line 17) moved after 45s - was: delay
```

## Tech Stack

| Component | Technology |
|-----------|------------|
| Framework | Phoenix 1.8 (Elixir) |
| Database | PostgreSQL 17 + PostGIS 3.5 |
| Real-time Data | GTFS-RT via [mkuran.pl](https://mkuran.pl/gtfs/) |
| Concurrency | OTP (GenServer, DynamicSupervisor, Registry) |

## Quick Start

```bash
# Start database
docker compose up -d

# Setup
mix deps.get
mix ecto.setup

# Import spatial data
wget https://mkuran.pl/gtfs/warsaw.zip -O /tmp/warsaw.zip
unzip -j /tmp/warsaw.zip stops.txt -d priv/data/
mix waw_trams.import_stops
mix waw_trams.import_intersections

# Run
mix phx.server
```

See [Data Sources Guide](guides/data_sources.md) for details on stops and intersections data.

## Database Schema

### `delay_events` — Persisted delays

| Column | Type | Description |
|--------|------|-------------|
| `vehicle_id` | string | e.g., "V/17/5" |
| `line` | string | Tram line number |
| `lat`, `lon` | float | Location when stopped |
| `started_at` | datetime | When delay began |
| `resolved_at` | datetime | When tram moved (nullable) |
| `duration_seconds` | integer | Total delay duration |
| `classification` | string | `blockage`, `delay` |
| `at_stop` | boolean | Was near a platform? |
| `near_intersection` | boolean | Was near a tram-road crossing? |

### `stops` — Transit platforms

~4,900 Warsaw Zone 1 stops with PostGIS geometry. Includes `is_terminal` flag for pętla/zajezdnia/P+R stops (73 terminals).

### `intersections` — Tram-road crossings

~1,250 intersections from OpenStreetMap with PostGIS geometry.

## Mix Tasks

```bash
# Import stops from GTFS
mix waw_trams.import_stops

# Import intersections from CSV
mix waw_trams.import_intersections

# Cleanup delay events
mix waw_trams.cleanup                    # Delete all
mix waw_trams.cleanup --resolved         # Delete only resolved
mix waw_trams.cleanup --older-than 7     # Delete older than N days
```

## Query Examples

```elixir
# Active delays right now
WawTrams.DelayEvent.active()

# Stats from last 24 hours
WawTrams.DelayEvent.stats()
# => [%{classification: "delay", count: 15, avg_duration_seconds: 45.2}, ...]

# Recent delay events
WawTrams.DelayEvent.recent(100)

# Check terminal stops count
WawTrams.Stop.terminal_count()
# => 73

# Hot spot analysis - top problematic intersections (clustered within 30m)
WawTrams.DelayEvent.hot_spots(limit: 10)
# => [%{cluster_id: 5, osm_ids: ["123", "124"], delay_count: 15, ...}, ...]

# Summary of intersection delays
WawTrams.DelayEvent.hot_spot_summary()
# => %{intersection_count: 12, total_delays: 47, total_delay_minutes: 35}
```

## Project Status

### Completed

- [x] PostgreSQL + PostGIS setup (Docker)
- [x] Stops table (~4,900 Warsaw Zone 1 stops)
- [x] Intersections table (~1,250 tram-road crossings)
- [x] Terminal stop detection (73 pętla/zajezdnia/P+R stops)
- [x] Import tasks (`mix waw_trams.import_stops`, `mix waw_trams.import_intersections`)
- [x] Proximity queries (`Stop.near_stop?/3`, `Intersection.near_intersection?/3`)
- [x] GTFS-RT Poller (fetches from mkuran.pl every 10s)
- [x] TramSupervisor (DynamicSupervisor for ~300 trams)
- [x] TramWorker (per-vehicle state, speed calculation, delay detection)
- [x] DelayEvent persistence (only significant delays stored)
- [x] Terminal filtering (no false positives at pętla/zajezdnia)
- [x] Real-time dashboard (Phoenix LiveView at `/dashboard`)
- [x] Cleanup task (`mix waw_trams.cleanup`)
- [x] Intersection delay aggregation/ranking (hot spots)
- [x] Test coverage for spatial queries

### Planned

**Map Visualization:**
- [x] `/map` page with Leaflet + OSM tiles + hot spot markers
- [x] Marker popups with delay details (count, lines, total time)
- [x] Marker clustering for dense areas

**Analytics:**
- [ ] Historical analysis queries

## Dashboard

Real-time dashboard available at `/dashboard`:
- Active delays with live updates
- Recently resolved delays
- Statistics by classification

## License

TBD
