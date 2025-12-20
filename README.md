# Warsaw Tram Priority Auditor

[![CI](https://github.com/patrykwozinski/waw_trams/actions/workflows/ci.yml/badge.svg)](https://github.com/patrykwozinski/waw_trams/actions/workflows/ci.yml)
[![Docs](https://github.com/patrykwozinski/waw_trams/actions/workflows/docs.yml/badge.svg)](https://patrykwozinski.github.io/waw_trams/)

Real-time detection and analysis of delays in the Warsaw tram network (ZTM), identifying intersections where traffic signal priority fails.

**[📚 Documentation](https://patrykwozinski.github.io/waw_trams/)** — API reference, guides, and architecture

## Problem

Warsaw's trams frequently wait at red lights because the traffic signal priority system doesn't work properly. **Goal:** Identify which intersections waste the most time and money, to support transit priority advocacy with data.

## What It Detects

| Location | Duration | What We Log |
|----------|----------|-------------|
| **At terminal** | Any | ❌ Ignored |
| **At stop** | ≤ 3 min | ❌ Ignored (normal boarding) |
| **At stop** | > 3 min | ✅ `blockage` (counts time after 3 min) |
| **Not at stop** | ≤ 30s | ❌ Ignored (brief) |
| **Not at stop** | > 30s | ✅ `delay` (counts time after 30s) |

**Important:** We only count *abnormal* delay time. If a tram stops for 90s at an intersection, only 60s is logged (90s - 30s threshold).

## Live Features

### Real-Time Map

- **Live bubbles** show active delays with ticking cost
- **Intersection names** displayed (e.g., "Rondo ONZ")
- **Cash-out effect** when delay resolves (floats up in amber)

### Global Counter

The headline counter **ticks live** including all active delays:

```
4,230 zł Wasted
Today • 47 delays • 2h 15m lost
```

The number updates every 250ms as trams wait at red lights.

## Quick Start

```bash
# Start database (PostGIS required)
docker compose up -d

# Setup
mix deps.get
mix ecto.setup

# Run
mix phx.server
```

Visit http://localhost:4000

> **First run:** The Seeder automatically imports ~1,250 intersections, ~4,900 stops, and ~172 line terminals from GTFS.

## Pages

| Route | Description |
|-------|-------------|
| `/` | 🚨 **Audit Dashboard** — live map with ticking delays, global cost counter |
| `/dashboard` | Real-time feed: active delays, recently resolved, impacted lines |
| `/line/:number` | Per-line analysis with hourly breakdown |

**Language:** Switch between 🇬🇧 English and 🇵🇱 Polish via header buttons.

## Cost Calculation

Economic cost per delay (uses *abnormal* time only):

```
Total Cost = Passenger Cost + Operational Cost

Passenger Cost = abnormal_hours × passengers × 22 PLN/hour
Operational Cost = abnormal_hours × (80 PLN/hour driver + 5 PLN/hour energy)
```

**Passenger estimates by time of day:**

| Period | Hours | Passengers |
|--------|-------|------------|
| Peak | 7–9, 15–18 | 150 |
| Off-Peak | 6, 9–15, 18–22 | 50 |
| Night | 22–6 | 10 |

## Tech Stack

| Component | Technology |
|-----------|------------|
| Framework | Phoenix 1.8 (Elixir/OTP) |
| Database | PostgreSQL 17 + PostGIS 3.5 |
| Caching | Built-in ETS (no external dependencies) |
| Maps | Leaflet.js |
| Data Source | GTFS-RT via [mkuran.pl](https://mkuran.pl/gtfs/) |
| CI/CD | GitHub Actions |

### Budget-Friendly Design

Optimized for **$5/month hosting** with:
- **ETS query cache** — reduces DB queries by ~99%
- **Staggered refresh timers** — prevents thundering herd
- **Small DB pool** — default 5 connections

## Development

```bash
# Run tests
mix test

# Run all checks (format, compile, test)
mix precommit

# Static analysis
mix credo
```

## Documentation

### For Everyone
- [Detection Logic](guides/detection_logic.md) — How we identify delays

### For Tramwaje Warszawskie / City Hall
- [**Thresholds**](guides/thresholds.md) — All configurable values, validation questions

### For Developers
- [Architecture](guides/architecture.md) — OTP supervision tree, data flow
- [Performance](guides/performance.md) — Caching, optimization, scaling
- [Data Sources](guides/data_sources.md) — How to import stops, intersections, terminals
- [Data Aggregation](guides/data_aggregation.md) — Hourly aggregation strategy
- [API Reference](guides/api.md) — Query functions and Mix tasks

## License

TBD
