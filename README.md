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

# Import spatial data (all auto-download GTFS as needed)
mix waw_trams.import_intersections   # From repo (OSM data)
mix waw_trams.import_stops           # Auto-downloads GTFS
mix waw_trams.import_line_terminals  # Reuses downloaded GTFS

# Run
mix phx.server
```

## Dashboard & Analytics

| Route | Description |
|-------|-------------|
| `/dashboard` | Real-time delays with **live timers**, hot spots, impacted lines |
| `/map` | Leaflet map with clustered delay markers |
| `/heatmap` | Hour × Day pattern visualization |
| `/line/:number` | Per-line analysis with hourly breakdown |

**Language:** Switch between 🇬🇧 English and 🇵🇱 Polish via the header buttons.

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
- [**Signal Timing**](guides/signal_timing.md) — Warsaw signal cycle info, double-stop merge
- [Data Sources](guides/data_sources.md) — Stops, intersections, GTFS-RT
- [Data Aggregation](guides/data_aggregation.md) — Hourly aggregation for scalable analytics
- [API Reference](guides/api.md) — Query functions and Mix tasks

## License

TBD
