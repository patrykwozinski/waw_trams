# Warsaw Tram Priority Auditor

Real-time detection and analysis of delays in the Warsaw tram network (ZTM), identifying inefficient traffic signal timing.

## Problem

Warsaw's tram network experiences delays from traffic light inefficiency, accidents, and normal boarding. **Goal:** Identify which intersections cause the most delays for transit priority advocacy.

## Key Insight

**57% of tram-road intersections have a stop within 50m.** This means we can't classify delays as "light" vs "boarding" in real-time. Instead:

1. Detect all unusual stops (time-based)
2. Log with location
3. Analyze post-hoc which intersections accumulate the most delay

## Architecture

```
WawTrams.Application
└── Supervisor
    ├── Registry (TramRegistry)
    ├── Poller (GenServer) ─── fetches GTFS-RT every 10s
    └── TramSupervisor (DynamicSupervisor)
        └── TramWorker × ~300 ─── one process per active tram
```

## Detection Logic

```
Tram stopped (speed < 3 km/h):

├── AT STOP (within 50m)
│   ├── < 60s   → normal_dwell (ignore)
│   ├── 60-120s → extended_dwell (log)
│   └── > 120s  → blockage (log)
│
└── NOT AT STOP
    └── > 30s   → delay (log)
```

Logs once per event, plus escalation and resolution:
```
[DELAY] Vehicle V/17/5 (Line 17) stopped for 35s...
[DELAY ESCALATED] Vehicle V/17/5... delay -> blockage
[RESOLVED] Vehicle V/17/5 moved after 215s...
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

## Project Status

### Completed

- [x] PostgreSQL + PostGIS setup (Docker)
- [x] Stops table (~4,900 Warsaw Zone 1 stops)
- [x] Intersections table (~1,250 tram-road crossings)
- [x] Import tasks (`mix waw_trams.import_stops`, `mix waw_trams.import_intersections`)
- [x] Proximity queries (`Stop.near_stop?/3`, `Intersection.near_intersection?/3`)
- [x] GTFS-RT Poller (fetches from mkuran.pl every 10s)
- [x] TramSupervisor (DynamicSupervisor)
- [x] TramWorker (per-vehicle state, delay detection)
- [x] Test coverage for spatial queries

### Planned

- [ ] Alerts table (persist delays to DB)
- [ ] Real-time dashboard (Phoenix LiveView)
- [ ] Intersection "hot spot" analysis
- [ ] Terminal stop whitelist

## License

TBD
