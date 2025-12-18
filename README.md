# Warsaw Tram Priority Auditor

Real-time detection and analysis of delays in the Warsaw tram network (ZTM), identifying inefficient traffic signal timing for transit priority advocacy.

## Problem

Warsaw's trams experience delays from traffic lights, accidents, and normal boarding. **Goal:** Identify which intersections cause the most delays to support transit priority improvements.

## Quick Start

```bash
# Start database
docker compose up -d

# Setup
mix deps.get
mix ecto.setup

# Import spatial data (see guides/data_sources.md for details)
wget https://mkuran.pl/gtfs/warsaw.zip -O /tmp/warsaw.zip
unzip -j /tmp/warsaw.zip stops.txt -d priv/data/
mix waw_trams.import_stops
mix waw_trams.import_intersections

# Run
mix phx.server
```

## Dashboard & Analytics

| Route | Description |
|-------|-------------|
| `/dashboard` | Real-time delays, hot spots, impacted lines |
| `/map` | Leaflet map with clustered delay markers |
| `/heatmap` | Hour × Day pattern visualization |
| `/line` | Per-line analysis with hourly breakdown |

## Tech Stack

| Component | Technology |
|-----------|------------|
| Framework | Phoenix 1.8 (Elixir/OTP) |
| Database | PostgreSQL 17 + PostGIS 3.5 |
| Data Source | GTFS-RT via [mkuran.pl](https://mkuran.pl/gtfs/) |

## Documentation

- [Architecture](guides/architecture.md) — System design, OTP supervision tree
- [Detection Logic](guides/detection_logic.md) — How delays are classified
- [**Thresholds**](guides/thresholds.md) — All configurable values (for validation with TW)
- [Data Sources](guides/data_sources.md) — Stops, intersections, GTFS-RT
- [Data Aggregation](guides/data_aggregation.md) — Hourly aggregation for scalable analytics
- [API Reference](guides/api.md) — Query functions and Mix tasks

## License

TBD
