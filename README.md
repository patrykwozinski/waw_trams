# Warsaw Tram Priority Auditor

Real-time detection and analysis of delays in the Warsaw tram network (ZTM), with a focus on identifying inefficient traffic signal timing.

## Problem

Warsaw's tram network experiences delays from multiple sources:

| Cause | Description | Fixable? |
|-------|-------------|----------|
| **Traffic light inefficiency** | Trams waiting at intersections due to poor signal priority | ✅ Yes — advocacy target |
| **Passenger boarding** | Normal dwell time at stops | ❌ No — expected |
| **Accidents/traffic** | Blockages from collisions, breakdowns | ⚠️ Partially |

**Goal:** Identify which intersections cause the most delays, providing data for transit priority advocacy.

## Key Insight: Stop-Intersection Overlap

Analysis of Warsaw's spatial data reveals:

| Metric | Value |
|--------|-------|
| Total stops (Zone 1) | ~4,900 |
| Total tram-road intersections | ~1,250 |
| **Intersections with stop within 50m** | **714 (57%)** |
| Closest overlap | Metro Politechnika: 4m |

**57% of intersections have a tram stop right next to them.** This is common urban design — stops often sit directly before/after traffic lights.

This means we **cannot reliably classify** a delay as "light delay" vs "boarding" in real-time. Instead, we:
1. Detect **all** unusual stops (time-based)
2. Log them with location
3. Analyze **post-hoc** which intersections accumulate the most delay time

## Architecture

```
WawTrams.Application
└── Supervisor
    ├── WawTrams.Poller (GenServer)
    │   Fetches fleet data every 10s from ZTM API
    │   Dispatches updates to individual tram workers
    │
    └── WawTrams.TramSupervisor (DynamicSupervisor)
        ├── TramWorker (VehicleNumber: "1001")
        ├── TramWorker (VehicleNumber: "1002")
        └── ... (~450 concurrent processes)
```

### Why This Design?

- **One process per tram** — Each vehicle maintains its own state (position history, timestamps). Elixir/OTP handles hundreds of lightweight processes trivially.
- **Fault isolation** — A crash in one tram's logic doesn't affect others.
- **Natural concurrency** — Speed calculations and proximity checks happen in parallel across all vehicles.

## Data Flow

```
ZTM API ──(10s)──► Poller ──► Dispatcher ──► TramWorker(s)
                                                  │
                                                  ▼
                                            Speed < 3 km/h?
                                            Duration > threshold?
                                                  │
                                                  ▼
                                            Alert ──► PostgreSQL
                                                  │
                                                  ▼
                                            Post-hoc Analysis
                                            (intersection correlation)
```

## Detection Logic

### Time-Based Classification

Since we can't distinguish "boarding" from "waiting at light" in real-time (57% overlap!), we use **duration** as the primary signal:

```
Tram stopped (speed < 3 km/h):

├── AT STOP (within 50m of platform)
│   ├── < 60s   → NORMAL_DWELL      (skip, expected)
│   ├── 60-120s → EXTENDED_DWELL    (log, might be light delay)
│   └── > 120s  → BLOCKAGE          (log, definitely abnormal)
│
└── NOT AT STOP
    └── > 30s   → DELAY             (log, something's wrong)
```

### Why This Works

| Duration | At Stop | Not At Stop | Interpretation |
|----------|---------|-------------|----------------|
| < 30s | Normal | GPS noise | Ignore |
| 30-60s | Normal boarding | Suspicious | Log if not at stop |
| 60-120s | Long boarding OR light | Definite delay | Log both |
| > 120s | Something's wrong | Something's wrong | Alert |

### Post-Hoc Intersection Analysis

After collecting delay events, correlate with intersection locations:

```sql
-- Find problematic intersections (most total delay time)
SELECT 
    i.osm_id,
    COUNT(*) as delay_count,
    SUM(a.duration_seconds) as total_delay_seconds,
    AVG(a.duration_seconds) as avg_delay_seconds
FROM alerts a
JOIN intersections i 
    ON ST_DWithin(a.geom::geography, i.geom::geography, 50)
WHERE a.detected_at > NOW() - INTERVAL '7 days'
GROUP BY i.osm_id
ORDER BY total_delay_seconds DESC
LIMIT 20;
```

This answers: *"Which intersections should get better signal priority?"*

## Tech Stack

| Component | Technology |
|-----------|------------|
| Framework | Phoenix 1.8 (Elixir) |
| Database | PostgreSQL 17 + PostGIS 3.5 |
| HTTP Client | Req |
| Spatial Data | GTFS (stops), OpenStreetMap (intersections) |
| Concurrency | OTP (GenServer, DynamicSupervisor) |

## External Data Sources

### ZTM Vehicle Positions API

**Endpoint:** `https://api.um.warszawa.pl/api/action/busestrams_get/`

**Parameters:**
- `resource_id` — Dataset identifier
- `type` — `2` for trams
- `apikey` — Your API key

**Response Fields:**

| Field | Type | Description |
|-------|------|-------------|
| `VehicleNumber` | string | Unique vehicle ID |
| `Lat` | string | Latitude (e.g., `"52.2297"`) |
| `Lon` | string | Longitude (e.g., `"21.0122"`) |
| `Time` | string | Timestamp |
| `Lines` | string | Line number |
| `Brigade` | string | Crew identifier |

> ⚠️ **Note:** `Lat` and `Lon` are returned as **strings** and may contain whitespace. Must be trimmed and parsed to floats.

### GTFS Stop Data

Source: [mkuran.pl/gtfs](https://mkuran.pl/gtfs/) — community-maintained, cleaner than raw ZTM FTP.

See [Data Sources Guide](guides/data_sources.md) for download and import instructions.

### OpenStreetMap Intersections

Tram-road intersection points extracted via Overpass API.

See [Data Sources Guide](guides/data_sources.md) for the query and import process.

## Database Schema

### `stops` Table

| Column | Type | Description |
|--------|------|-------------|
| `id` | bigint | Primary key |
| `stop_id` | string | GTFS stop_id (e.g., "100101") |
| `name` | string | Stop name (e.g., "Kijowska") |
| `geom` | geometry(Point, 4326) | PostGIS point |

**Spatial Index:** `stops_geom_idx` (GIST)

### `intersections` Table

| Column | Type | Description |
|--------|------|-------------|
| `id` | bigint | Primary key |
| `osm_id` | string | OpenStreetMap node ID |
| `geom` | geometry(Point, 4326) | PostGIS point |

**Spatial Index:** `intersections_geom_idx` (GIST)

### `alerts` Table (Planned)

| Column | Type | Description |
|--------|------|-------------|
| `id` | bigint | Primary key |
| `vehicle_number` | string | Tram ID |
| `line` | string | Line number |
| `geom` | geometry(Point, 4326) | Location |
| `detected_at` | utc_datetime | When delay started |
| `resolved_at` | utc_datetime | When tram moved |
| `duration_seconds` | integer | Total delay duration |
| `at_stop` | boolean | Was within 50m of stop? |
| `near_intersection` | boolean | Was within 50m of intersection? |
| `classification` | string | `normal_dwell`, `extended_dwell`, `delay`, `blockage` |

## Configuration

### Environment Variables

```bash
# Required
export ZTM_API_KEY="your-api-key-here"
```

### Runtime Config

```elixir
# config/runtime.exs
config :waw_trams,
  ztm_api_key: System.get_env("ZTM_API_KEY")
```

### Application Config

```elixir
# config/config.exs
config :waw_trams,
  # Polling
  poll_interval_ms: 10_000,
  
  # Detection thresholds
  speed_threshold_kmh: 3.0,
  stop_proximity_meters: 50,
  intersection_proximity_meters: 50,
  
  # Duration thresholds (seconds)
  normal_dwell_max: 60,
  extended_dwell_max: 120,
  delay_min_not_at_stop: 30,
  
  # Worker management
  worker_idle_timeout_ms: 300_000  # 5 minutes
```

## Development

### Prerequisites

- Elixir 1.17+
- Docker (for PostgreSQL + PostGIS)

### Quick Start

```bash
# 1. Start database
docker compose up -d

# 2. Install dependencies
mix deps.get

# 3. Setup database
mix ecto.setup

# 4. Download and import spatial data
wget https://mkuran.pl/gtfs/warsaw.zip -O /tmp/warsaw.zip
unzip -j /tmp/warsaw.zip stops.txt -d priv/data/
mix waw_trams.import_stops
mix waw_trams.import_intersections

# 5. Start server
mix phx.server
```

### Database Commands

```bash
docker compose up -d      # Start PostgreSQL
docker compose down       # Stop
docker compose down -v    # Stop and delete data
```

### Running Tests

```bash
mix test                  # Run all tests
mix test --failed         # Re-run failed tests
```

### Before Committing

```bash
mix precommit             # Format, lint, test
```

## Project Status

### Completed

- [x] Project architecture and documentation
- [x] PostgreSQL + PostGIS setup (Docker)
- [x] Stops table with spatial index
- [x] Intersections table with spatial index
- [x] GTFS import task (`mix waw_trams.import_stops`)
- [x] OSM import task (`mix waw_trams.import_intersections`)
- [x] Proximity query functions (`Stop.near_stop?/3`, `Intersection.near_intersection?/3`)
- [x] Test coverage for spatial queries

### In Progress

- [ ] Poller GenServer (ZTM API integration)
- [ ] TramWorker GenServer (per-vehicle state)
- [ ] DynamicSupervisor for worker management

### Planned

- [ ] Alerts table and persistence
- [ ] Real-time dashboard (Phoenix LiveView)
- [ ] Historical analysis queries
- [ ] Intersection "hot spot" visualization
- [ ] Webhook/notification system

## License

TBD
