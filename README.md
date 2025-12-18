# Warsaw Tram Priority Auditor

Real-time detection and classification of delays in the Warsaw tram network (ZTM).

## Problem

Warsaw's tram network experiences delays from two primary sources:
1. **Traffic light inefficiency** — Trams waiting at intersections due to poor signal priority
2. **Accidents/traffic** — Blockages from collisions, breakdowns, or road congestion

This system distinguishes between these causes by analyzing movement patterns in real-time.

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

- **One process per tram** — Each vehicle maintains its own state (position history, current speed). Elixir/OTP handles hundreds of lightweight processes trivially.
- **Fault isolation** — A crash in one tram's logic doesn't affect others.
- **Natural concurrency** — Speed calculations happen in parallel across all vehicles.

## Data Flow

```
ZTM API ──(10s)──► Poller ──► Dispatcher ──► TramWorker(s)
                                                  │
                                                  ▼
                                            Speed < 3 km/h?
                                            Not near stop?
                                                  │
                                                  ▼
                                            Alert ──► PostgreSQL
```

## Detection Logic

### Delay Trigger

A tram is flagged as **potentially delayed** when:

| Condition | Threshold |
|-----------|-----------|
| Speed | < 3 km/h |
| Distance to nearest stop | > 50m |
| Duration | > 30s |

### Classification (Inferred)

| Type | Criteria |
|------|----------|
| `light` | Short stop (30s–90s), single vehicle |
| `accident` | Long stop (> 2min) OR multiple trams clustered |
| `unknown` | Doesn't fit above patterns |

> **Note:** Classification accuracy improves with intersection data (future enhancement).

## Tech Stack

| Component | Technology |
|-----------|------------|
| Framework | Phoenix (Elixir) |
| Database | PostgreSQL + PostGIS |
| HTTP Client | Req |
| Stop Data | ZTM GTFS |
| Concurrency | OTP (GenServer, DynamicSupervisor) |

## External Data Sources

### ZTM Vehicle Positions API

**Endpoint:** `https://api.um.warszawa.pl/api/action/busestrams_get/`

**Parameters:**
- `resource_id` — Dataset identifier
- `type` — `2` for trams
- `apikey` — Your API key

**Expected Response Fields:**

| Field | Type | Description |
|-------|------|-------------|
| `VehicleNumber` | string | Unique vehicle ID |
| `Lat` | string | Latitude (as string, e.g., `"52.2297"`) |
| `Lon` | string | Longitude (as string, e.g., `"21.0122"`) |
| `Time` | string | Timestamp |
| `Lines` | string | Line number |
| `Brigade` | string | Crew identifier |

> **Note:** `Lat` and `Lon` are returned as strings in the JSON response and may contain whitespace. Must be trimmed and parsed to floats.

### GTFS Stop Data

Stop locations loaded from ZTM GTFS feed (`stops.txt`).

Used for:
- Proximity checks (is tram near a stop?)
- Filtering out legitimate dwell time at stops

## Database Schema

### `alerts` Table

| Column | Type | Description |
|--------|------|-------------|
| `id` | bigint | Primary key |
| `vehicle_number` | string | Tram ID |
| `line` | string | Line number |
| `lat` | float | Location |
| `lon` | float | Location |
| `detected_at` | utc_datetime | When delay started |
| `resolved_at` | utc_datetime | When tram moved again |
| `duration_seconds` | integer | Total delay duration |
| `classification` | string | `light`, `accident`, `unknown` |
| `inserted_at` | utc_datetime | Record creation |

### `stops` Table (PostGIS)

| Column | Type | Description |
|--------|------|-------------|
| `id` | bigint | Primary key |
| `stop_id` | string | GTFS stop_id |
| `name` | string | Stop name |
| `geom` | geometry(Point, 4326) | PostGIS point |

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

Tunable thresholds:

```elixir
# config/config.exs
config :waw_trams,
  poll_interval_ms: 10_000,
  speed_threshold_kmh: 3.0,
  stop_proximity_meters: 50,
  delay_min_duration_seconds: 30,
  worker_idle_timeout_ms: 300_000  # 5 minutes
```

## Development

```bash
# Setup
mix deps.get
mix ecto.setup

# Run
mix phx.server

# Tests
mix test

# Precommit checks
mix precommit
```

### Seeding Stop Data

Download GTFS data from ZTM and place `stops.txt` in `priv/data/`:

```bash
# Import stops into PostGIS
mix waw_trams.import_stops
```

This Mix task parses the standard GTFS `stops.txt` CSV format and populates the `stops` table with PostGIS geometries.

## Future Enhancements

- [ ] Intersection/traffic light dataset for accurate `light` classification
- [ ] Terminal whitelist to reduce false positives at end-of-line stops
- [ ] Real-time dashboard (Phoenix LiveView)
- [ ] Historical delay pattern analysis
- [ ] Webhook/notification system for severe delays

## License

TBD
