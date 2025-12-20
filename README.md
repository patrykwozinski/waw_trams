# Warsaw Tram Priority Auditor

[![CI](https://github.com/patrykwozinski/waw_trams/actions/workflows/ci.yml/badge.svg)](https://github.com/patrykwozinski/waw_trams/actions/workflows/ci.yml)
[![Docs](https://github.com/patrykwozinski/waw_trams/actions/workflows/docs.yml/badge.svg)](https://patrykwozinski.github.io/waw_trams/)

Real-time detection and analysis of delays in the Warsaw tram network (ZTM), identifying intersections where traffic signal priority fails.

**[📚 Documentation](https://patrykwozinski.github.io/waw_trams/)** — API reference, guides, and architecture

## Problem

Warsaw's trams frequently wait at red lights because the traffic signal priority system doesn't work properly. **Goal:** Identify which intersections waste the most time and money, to support transit priority advocacy with data.

## What It Detects

| Location | Duration | What We Log | Priority Failure? |
|----------|----------|-------------|-------------------|
| **At terminal** | Any | ❌ Ignored | — |
| **At stop** | ≤ 3 min | ❌ Ignored (normal boarding) | — |
| **At stop** | > 3 min | ✅ `blockage` | Only if near intersection AND > 180s |
| **Not at stop** | ≤ 30s | ❌ Ignored (brief) | — |
| **Not at stop** | > 30s | ✅ `delay` | If near intersection AND > 120s |

**Priority Failure** = tram waited through multiple signal cycles (120s+) because the traffic signal priority system failed to give it a green light.

## Quick Start

```bash
# Start database (PostGIS required)
docker compose up -d

# Setup
mix deps.get
mix ecto.setup

# Import spatial data
mix waw_trams.import_intersections   # ~1,250 tram-road crossings with street names
mix waw_trams.import_stops           # ~4,900 Warsaw platforms
mix waw_trams.import_line_terminals  # ~172 line-specific terminals

# Run
mix phx.server
```

Visit http://localhost:4000

## Pages & Navigation

| Route | Description |
|-------|-------------|
| `/` | 🚨 **Infrastructure Report Card** — worst intersections ranked by economic cost (homepage) |
| `/dashboard` | Real-time delays, hot spots, impacted lines |
| `/line/:number` | Per-line analysis with hourly breakdown |

**Language:** Switch between 🇬🇧 English and 🇵🇱 Polish via header buttons.

## Key Metrics

| Metric | What It Means |
|--------|---------------|
| **Delays** | All logged delay events (>30s not at stop, or >180s at stop) |
| **Priority Failures** | Delays at intersections exceeding threshold (120s or 180s if at stop) |
| **Economic Cost** | Time × passengers × value-of-time + driver wages + energy |

### Cost Calculation

The economic cost is calculated per delay event:

```
Total Cost = Passenger Cost + Operational Cost

Passenger Cost = delay_hours × passengers × 22 PLN/hour (Value of Time)
Operational Cost = delay_hours × (80 PLN/hour driver + 5 PLN/hour energy)
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
- [Detection Logic](guides/detection_logic.md) — How we identify delays and priority failures

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
