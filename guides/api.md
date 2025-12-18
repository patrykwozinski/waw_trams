# API Reference

## Query Functions

### Active Delays

```elixir
# Currently active (unresolved) delays
WawTrams.DelayEvent.active()
# => [%DelayEvent{...}, ...]
```

### Statistics

```elixir
# Stats from last 24 hours
WawTrams.DelayEvent.stats()
# => [%{classification: "delay", count: 15, avg_duration_seconds: 45.2}, ...]

# Stats from custom period
WawTrams.DelayEvent.stats(DateTime.add(DateTime.utc_now(), -7, :day))
```

### Recent Events

```elixir
# Last 100 delay events
WawTrams.DelayEvent.recent(100)
```

### Hot Spots (Intersection Analysis)

```elixir
# Top problematic intersections (clustered within 30m)
WawTrams.DelayEvent.hot_spots(limit: 10)
# => [%{cluster_id: 5, osm_ids: ["123", "124"], delay_count: 15, ...}, ...]

# Summary of intersection delays
WawTrams.DelayEvent.hot_spot_summary()
# => %{intersection_count: 12, total_delays: 47, total_delay_minutes: 35}
```

### Line Analysis

```elixir
# Most impacted lines (by total delay time)
WawTrams.DelayEvent.impacted_lines(limit: 10)

# Delays by hour for a specific line
WawTrams.DelayEvent.delays_by_hour("17")

# Line summary
WawTrams.DelayEvent.line_summary("17")

# Lines with recorded delays
WawTrams.DelayEvent.lines_with_delays()
```

### Heatmap Data

```elixir
# Hour × Day of week aggregation
WawTrams.DelayEvent.heatmap_data(since: DateTime.add(DateTime.utc_now(), -7, :day))

# Structured grid for rendering
WawTrams.DelayEvent.heatmap_grid()
```

### Spatial Queries

```elixir
# Check if point is near a stop (within 50m default)
WawTrams.Stop.near_stop?(52.2297, 21.0122)
WawTrams.Stop.near_stop?(52.2297, 21.0122, 100)  # custom radius

# Check if point is near a terminal
WawTrams.Stop.near_terminal?(52.2297, 21.0122)

# Check if point is near an intersection
WawTrams.Intersection.near_intersection?(52.2297, 21.0122)

# Terminal stop count
WawTrams.Stop.terminal_count()
# => 73
```

## Mix Tasks

### Import Data

```bash
# Import stops from GTFS (requires priv/data/stops.txt)
mix waw_trams.import_stops

# Import intersections from CSV (requires priv/data/intersections.csv)
mix waw_trams.import_intersections
```

### Cleanup

```bash
# Delete all delay events
mix waw_trams.cleanup

# Delete only resolved events
mix waw_trams.cleanup --resolved

# Delete events older than N days
mix waw_trams.cleanup --older-than 7

# Combine options
mix waw_trams.cleanup --resolved --older-than 3
```

### Documentation

```bash
# Generate docs (includes guides)
mix docs
```

