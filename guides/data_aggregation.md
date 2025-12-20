# Data Aggregation Strategy

> **Audience:** Developers maintaining or extending the analytics pipeline

As `delay_events` grows (~14k/day), complex spatial queries become expensive. This document outlines the aggregation strategy for long-term sustainability.

## Problem

| Current Growth | Impact |
|----------------|--------|
| ~14,000 events/day | ~5M events/year |
| ~80 MB/month | ~1 GB/year |
| Complex spatial clustering | Slow queries as data grows |

## Solution: Hourly Aggregation

Keep raw events for 7 days (debugging/recovery), aggregate hourly for fresh stats.

```
┌─────────────────────────────────────────────────────────────────┐
│  delay_events (RAW)            │  Keep 7 days (configurable)   │
│  - Full detail for real-time   │  ~100k rows max               │
│  - Dashboard live feed         │  Available for debugging      │
└─────────────────────────────────────────────────────────────────┘
                      ↓ Hourly aggregation (minute 5 of each hour)
┌─────────────────────────────────────────────────────────────────┐
│  daily_intersection_stats      │  Keep forever                 │
│  - Per location per day        │  ~50 rows/day                 │
│  - Updated hourly (additive)   │  Supports: hot_spots, map     │
├─────────────────────────────────────────────────────────────────┤
│  hourly_intersection_stats     │  Keep forever                 │
│  - Per location per hour       │  ~500 rows/day                │
│  - Pre-calculated cost         │  Supports: Audit Dashboard    │
├─────────────────────────────────────────────────────────────────┤
│  daily_line_stats              │  Keep forever                 │
│  - Per line per day            │  ~30 rows/day                 │
│  - Updated hourly (additive)   │  Supports: line analysis      │
├─────────────────────────────────────────────────────────────────┤
│  hourly_patterns               │  Keep forever                 │
│  - Per hour × day_of_week      │  168 rows total (cumulative)  │
│  - Updated hourly              │  Supports: heatmap            │
└─────────────────────────────────────────────────────────────────┘
```

### Why Hourly + 7 Day Retention?

| Benefit | Explanation |
|---------|-------------|
| Fresh data | All analytics include events up to ~5 min ago |
| Recovery ability | Can recompute/debug with raw data for 7 days |
| Consistent freshness | Aggregated + events since :05 = same ~5min lag everywhere |
| Safe cleanup | Only deletes data that's been aggregated |
| No double-counting | Events before :05 only in aggregated, after :05 added separately |

## Schema Design

### `daily_intersection_stats`

Aggregates delays by location per day. Location is rounded to 4 decimal places (~11m precision) for grouping.

```elixir
schema "daily_intersection_stats" do
  field :date, :date
  field :lat, :float              # Rounded to 4 decimals
  field :lon, :float              # Rounded to 4 decimals
  field :location_name, :string   # Street name (e.g., "Puławska / Goworka")
  field :delay_count, :integer
  field :blockage_count, :integer
  field :total_seconds, :integer
  field :affected_lines, {:array, :string}  # ["1", "9", "25"]
  
  timestamps()
end
```

**Indexes:** `[:date]`, `[:lat, :lon]`, `[:date, :lat, :lon]` (unique)

### `hourly_intersection_stats`

Aggregates delays by location per hour, with **pre-calculated cost** for fast Audit Dashboard queries.

```elixir
schema "hourly_intersection_stats" do
  field :date, :date
  field :hour, :integer              # 0-23
  field :lat, :float                 # Rounded to 4 decimals
  field :lon, :float                 # Rounded to 4 decimals
  field :delay_count, :integer
  field :total_seconds, :integer
  field :cost_pln, :float            # Pre-calculated using hour
  field :lines, {:array, :string}    # ["1", "9", "25"]
  
  timestamps()
end
```

**Indexes:** `[:date, :hour, :lat, :lon]` (unique), `[:date, :cost_pln]`, `[:lat, :lon]`

**Cost calculation:** Uses `CostCalculator.calculate/2` which applies hour-specific passenger estimates (peak/off-peak/night) to calculate economic cost.

### `daily_line_stats`

Aggregates delays by line per day, with hourly breakdown.

```elixir
schema "daily_line_stats" do
  field :date, :date
  field :line, :string
  field :delay_count, :integer
  field :blockage_count, :integer
  field :total_seconds, :integer
  field :intersection_count, :integer  # Events near intersections
  field :by_hour, :map  # %{"6" => 3, "7" => 8, "8" => 12, ...}
  
  timestamps()
end
```

**Indexes:** `[:date]`, `[:line]`, `[:date, :line]` (unique)

### `hourly_patterns`

Cumulative counters for hour × day-of-week patterns (for heatmap).

```elixir
schema "hourly_patterns" do
  field :day_of_week, :integer    # 1 (Monday) - 7 (Sunday)
  field :hour, :integer           # 0-23
  field :delay_count, :integer    # Cumulative
  field :blockage_count, :integer # Cumulative
  field :total_seconds, :integer  # Cumulative
  
  timestamps()
end
```

**Indexes:** `[:day_of_week, :hour]` (unique)

**Note:** This table has exactly 168 rows (7 days × 24 hours). Aggregation task increments counters.

## Configuration

```elixir
# config/config.exs
config :waw_trams,
  # How long to keep raw delay_events
  raw_retention_days: 7,
  
  # Decimal places for location rounding (4 = ~11m precision)
  aggregation_precision: 4
```

## Query Routing

All analytics use **aggregated data + real-time additions** for consistent freshness (~5 min delay max).

| Query | Source |
|-------|--------|
| `hot_spots` | Aggregated + events since :05 |
| `impacted_lines` | Aggregated + events since :05 |
| `delays_by_hour` | Aggregated + events since :05 |
| `line_summary` | Aggregated + events since :05 |
| `heatmap_grid` | `hourly_patterns` (cumulative) |
| `active` | Raw (live) |
| `recent` | Raw (live) |

**For caching and performance optimization details, see [Performance](performance.md).**

## Storage Estimate

| Table | Rows/Year | Est. Size |
|-------|-----------|-----------|
| delay_events (7d) | ~100k max | ~20 MB |
| daily_intersection_stats | ~18k | ~2 MB |
| hourly_intersection_stats | ~180k | ~15 MB |
| daily_line_stats | ~11k | ~1 MB |
| hourly_patterns | 168 | ~10 KB |
| **Total** | | **~40 MB/year** |

**Savings:** ~90% storage reduction vs keeping all raw events.

---

## How It Works

### Automatic Aggregation (HourlyAggregator)

A GenServer runs at minute 5 of each hour, aggregating the previous hour's events:

```elixir
# Auto-starts with application (in supervision tree)
# Logs progress: [HourlyAggregator] Aggregated 45 events for 2025-12-18 15:00

# Manual trigger (if needed)
WawTrams.HourlyAggregator.aggregate_now()
WawTrams.HourlyAggregator.status()
```

### Manual Aggregation (Mix Task)

For backfilling historical data or manual runs:

```bash
# Aggregate yesterday (default)
mix waw_trams.aggregate_daily

# Aggregate specific date
mix waw_trams.aggregate_daily --date 2025-12-17

# Backfill last N days
mix waw_trams.aggregate_daily --backfill 7

# Preview without changes
mix waw_trams.aggregate_daily --dry-run
```

### Cleanup Workflow

```bash
# 1. Aggregate first
mix waw_trams.aggregate_daily --backfill 7

# 2. Preview cleanup (DRY RUN by default)
mix waw_trams.cleanup

# 3. Execute if preview looks correct
mix waw_trams.cleanup --execute
```

Output shows aggregation status:
- ✓ Aggregated (safe to delete)
- ✗ NOT aggregated (would lose data)
