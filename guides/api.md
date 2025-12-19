# API Reference

> **Audience:** Developers using the query functions and Mix tasks

## Module Structure

After Clean Architecture refactoring, queries are organized by domain:

```
lib/waw_trams/
├── queries/
│   ├── active_delays.ex   # Real-time delay tracking
│   ├── hot_spots.ex       # Intersection analysis
│   ├── heatmap.ex         # Hour × day patterns
│   └── line_analysis.ex   # Per-line statistics
├── analytics/
│   └── stats.ex           # Summary statistics
└── audit/
    ├── summary.ex         # City-wide audit stats
    ├── intersection.ex    # Single intersection detail
    └── cost_calculator.ex # Economic cost formulas
```

## Query Functions

### Active Delays (Real-Time)

```elixir
# Currently active (unresolved) delays
WawTrams.Queries.ActiveDelays.active()
# => [%DelayEvent{...}, ...]

# Recent resolved delays
WawTrams.Queries.ActiveDelays.recent(100)

# Recently resolved (last 20)
WawTrams.Queries.ActiveDelays.recent_resolved()

# Counts
WawTrams.Queries.ActiveDelays.count_active()
WawTrams.Queries.ActiveDelays.count_today()
```

### Statistics

```elixir
# Summary stats (last 24 hours default)
WawTrams.Analytics.Stats.summary()
# => %{delay_count: 45, blockage_count: 12, total_seconds: 3600, multi_cycle_count: 3, ...}

# Stats by classification
WawTrams.Analytics.Stats.for_period()
# => [%{classification: "delay", count: 45, avg_duration_seconds: 52.3}, ...]

# Priority failure count (intersection delays > threshold)
WawTrams.Analytics.Stats.multi_cycle_count()
# => 3
```

### Hot Spots (Intersection Analysis)

```elixir
# Top problematic intersections (clustered within ~55m)
WawTrams.Queries.HotSpots.hot_spots(limit: 10)
# => [%{lat: 52.23, lon: 21.01, delay_count: 15, nearest_stop: "Centrum", ...}, ...]

# Summary of intersection delays
WawTrams.Queries.HotSpots.hot_spot_summary()
# => %{intersection_count: 12, total_delays: 47, total_delay_minutes: 35}

# Most impacted lines (by total delay time)
WawTrams.Queries.HotSpots.impacted_lines(limit: 10)
```

### Line Analysis

```elixir
# Delays by hour for a specific line
WawTrams.Queries.LineAnalysis.delays_by_hour("17")

# Line summary (totals, averages)
WawTrams.Queries.LineAnalysis.summary("17")

# Worst intersections for a line
WawTrams.Queries.LineAnalysis.hot_spots("17", limit: 10)

# Lines with recorded delays
WawTrams.Queries.LineAnalysis.lines_with_delays()
```

### Heatmap Data

```elixir
# Hour × Day of week aggregation
WawTrams.Queries.Heatmap.data(since: DateTime.add(DateTime.utc_now(), -7, :day))

# Structured grid for rendering (168 cells: 24h × 7 days)
WawTrams.Queries.Heatmap.grid()
```

### Audit Dashboard

```elixir
# City-wide stats with economic cost
WawTrams.Audit.Summary.stats(since: DateTime.add(DateTime.utc_now(), -7, :day))
# => %{total_delays: 140, cost: %{total: 3330.51}, multi_cycle_count: 3, ...}

# Leaderboard (worst intersections by cost)
WawTrams.Audit.Summary.leaderboard(limit: 20)

# Single intersection heatmap
WawTrams.Audit.Intersection.heatmap(lat, lon, since: since)
```

### Spatial Queries

```elixir
# Check if point is near a stop (within 50m default)
WawTrams.Stop.near_stop?(52.2297, 21.0122)
WawTrams.Stop.near_stop?(52.2297, 21.0122, 100)  # custom radius

# Check if point is near an intersection
WawTrams.Intersection.near_intersection?(52.2297, 21.0122)

# Check if point is a terminal for a specific line
WawTrams.LineTerminal.terminal_for_line?("25", 52.2297, 21.0122)
# => true if line 25 terminates here, false otherwise
```

## Mix Tasks

### Import Data

```bash
# Import stops from GTFS (auto-downloads from mkuran.pl)
mix waw_trams.import_stops

# Import intersections from CSV (uses priv/data/intersections.csv)
mix waw_trams.import_intersections

# Import line-specific terminals from GTFS
mix waw_trams.import_line_terminals
mix waw_trams.import_line_terminals --dry-run  # preview only
```

### Cleanup

**Safe by default** — always shows preview first, requires `--execute` to delete.

```bash
# Preview what would be deleted (DRY RUN)
mix waw_trams.cleanup

# Actually delete old events
mix waw_trams.cleanup --execute

# Delete events older than N days (default: 7)
mix waw_trams.cleanup --older-than 14 --execute

# Reset all data (DANGEROUS - requires confirmation)
mix waw_trams.cleanup --reset-all --execute --i-know-what-i-am-doing
```

**`--reset-all` deletes:**
- `delay_events` (raw events)
- `daily_line_stats`, `daily_intersection_stats` (daily aggregates)
- `hourly_intersection_stats` (hourly aggregates for Audit)
- `hourly_patterns` (cumulative heatmap data)
- Also resets PostgreSQL statistics

### Aggregation

```bash
# Aggregate yesterday's data
mix waw_trams.aggregate_daily

# Backfill last N days
mix waw_trams.aggregate_daily --backfill 7

# Aggregate specific date
mix waw_trams.aggregate_daily --date 2025-12-15

# Preview only
mix waw_trams.aggregate_daily --dry-run
```

### Documentation

```bash
# Generate docs (includes guides)
mix docs
```
