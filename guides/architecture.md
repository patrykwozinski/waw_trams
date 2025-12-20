# Architecture

> **Audience:** Developers understanding the system design

## OTP Supervision Tree

```
WawTrams.Application
└── Supervisor
    ├── Registry (TramRegistry)
    ├── Poller (GenServer) ─── fetches GTFS-RT every 10s
    ├── Cache (GenServer) ─── ETS-backed query cache
    ├── HourlyAggregator (GenServer) ─── aggregates at minute 5 of each hour
    └── TramSupervisor (DynamicSupervisor)
        └── TramWorker × ~300 ─── one process per active tram
                │
                └── DelayEvent ─── persisted to PostgreSQL
```

## Components

### Poller

GenServer that fetches GTFS-Realtime vehicle positions every 10 seconds from mkuran.pl. Filters for tram vehicles (lines 1-79) and dispatches updates to individual TramWorkers.

### Cache

GenServer managing an ETS-based query cache. Reduces database load by caching expensive aggregation queries (30-60s TTL). See [Performance](performance.md) for details.

### HourlyAggregator

GenServer that runs at minute 5 of each hour, aggregating the previous hour's raw `delay_events` into summary tables (`daily_intersection_stats`, `daily_line_stats`, `hourly_patterns`). On startup, automatically catches up any missed hours from the last 24 hours. **Invalidates the query cache** after each aggregation run.

### TramSupervisor

DynamicSupervisor managing ~300 TramWorker processes. Workers are started on first vehicle sighting and restarted if they crash.

### TramWorker

One GenServer per active tram vehicle. Maintains state:
- Recent positions (last 5)
- Current speed (calculated from position history)
- Stop status (moving/stopped)
- Active delay event (if any)

On each position update:
1. Calculate speed from position history
2. Check if stopped (speed < 3 km/h)
3. Classify delay if stopped for threshold duration
4. Persist to database when thresholds are met

### DelayEvent

Ecto schema for persisted delays. Only actionable delays are stored:
- `delay` — stopped > 30s NOT at a stop (traffic/signal issue)
- `blockage` — stopped > 180s at a stop (abnormal dwell)

## Database Schema

### `delay_events`

| Column | Type | Description |
|--------|------|-------------|
| `vehicle_id` | string | e.g., "V/17/5" |
| `line` | string | Tram line number |
| `lat`, `lon` | float | Location when stopped |
| `started_at` | datetime | When delay began |
| `resolved_at` | datetime | When tram moved (nullable) |
| `duration_seconds` | integer | Total delay duration |
| `classification` | string | `blockage` or `delay` |
| `at_stop` | boolean | Was near a platform? |
| `near_intersection` | boolean | Was near a tram-road crossing? |

### `stops`

~4,900 Warsaw Zone 1 transit platforms with PostGIS geometry.

### `line_terminals`

~172 unique (line, stop_id) pairs extracted from GTFS trip data. Used for line-specific terminal detection — a stop like Pl. Narutowicza is a terminal for line 25 but a regular stop for line 15.

### `intersections`

~1,250 tram-road crossings from OpenStreetMap with PostGIS geometry and street names (e.g., "Puławska / Goworka"). Used for both spatial proximity checks and display names on the dashboard.

### Aggregation Tables

| Table | Purpose |
|-------|---------|
| `daily_intersection_stats` | Per-location per-day delay summaries |
| `daily_line_stats` | Per-line per-day delay summaries |
| `hourly_patterns` | Cumulative hour × day-of-week counters |

## Data Flow

```
GTFS-RT Feed (mkuran.pl)
    │
    ▼
Poller (fetch every 10s)
    │
    ├─▶ Filter trams (lines 1-79)
    │
    ▼
TramWorker (per vehicle)
    │
    ├─▶ Calculate speed
    ├─▶ Check stop proximity (PostGIS)
    ├─▶ Classify delay
    │
    ▼
DelayEvent (persist to DB)
    │
    ├─▶ PubSub broadcast ──────────────────────────┐
    │                                               │
    ▼                                               ▼
HourlyAggregator                          LiveView (real-time)
    │                                      - Instant UI update via PubSub
    ├─▶ Aggregate hourly                   - No DB query for live events
    ├─▶ Invalidate cache
    │
    ▼
Query Cache (ETS)  ◀────────────────────── LiveView (initial load)
    │                                      - Stats, leaderboard cached
    │                                      - TTL: 10-60 seconds
    ▼
Database (aggregated tables)
```

### Query Caching & Real-Time Strategy

- **Real-time updates** via PubSub are **NOT cached** — they update the UI instantly
- **Live cost ticking** — active delays calculate cost client-side (every 250ms)
- **Global counter** — includes both resolved (base) + active (live) costs
- **Periodic refreshes** use cached data (TTL 30-60s) to reduce database load
- **Audit leaderboard** is refreshed with a 3-second debounce when delays resolve

See [Performance](performance.md) for detailed cache configuration and scaling analysis.

