# Architecture

## OTP Supervision Tree

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

## Components

### Poller

GenServer that fetches GTFS-Realtime vehicle positions every 10 seconds from mkuran.pl. Filters for tram vehicles (lines 1-79) and dispatches updates to individual TramWorkers.

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

~4,900 Warsaw Zone 1 transit platforms with PostGIS geometry. Includes `is_terminal` flag for pętla/zajezdnia/P+R stops (73 terminals).

### `intersections`

~1,250 tram-road crossings from OpenStreetMap with PostGIS geometry.

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
    ▼
LiveView Dashboard (real-time updates)
```

