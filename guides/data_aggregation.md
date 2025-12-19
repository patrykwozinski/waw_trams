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
  field :nearest_stop, :string    # Cached for display
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
  field :multi_cycle_count, :integer # Priority failures (threshold depends on location)
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

```
┌─────────────────────────────────────────────────────────────────┐
│                     QUERY FLOW                                  │
│                                                                 │
│  Dashboard / Map / Line Analysis                                │
│              │                                                  │
│              ▼                                                  │
│        QueryRouter                                              │
│              │                                                  │
│              ├──► Aggregated data (from :05 of current hour)   │
│              │         + Events since :05 (real-time)          │
│              │                                                  │
│              └──► Result: Data up to ~5 minutes old            │
└─────────────────────────────────────────────────────────────────┘
```

| Query | Source |
|-------|--------|
| `hot_spots` | Aggregated + events since :05 |
| `impacted_lines` | Aggregated + events since :05 |
| `delays_by_hour` | Aggregated + events since :05 |
| `line_summary` | Aggregated + events since :05 |
| `heatmap_grid` | `hourly_patterns` (cumulative) |
| `active` | Raw (live) |
| `recent` | Raw (live) |

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

## Implementation Phases

### Phase 1: Schema & Tables ✅ COMPLETE

Create the aggregation tables.

**Tasks:**
- [x] Create migration for `daily_intersection_stats`
- [x] Create migration for `daily_line_stats`
- [x] Create migration for `hourly_patterns` (pre-populated with 168 rows)
- [x] Create Ecto schemas for all three
- [x] Add configuration options to `config.exs`

**Files created:**
- `priv/repo/migrations/20251218155009_create_daily_intersection_stats.exs`
- `priv/repo/migrations/20251218155011_create_daily_line_stats.exs`
- `priv/repo/migrations/20251218155013_create_hourly_patterns.exs`
- `lib/waw_trams/daily_intersection_stat.ex`
- `lib/waw_trams/daily_line_stat.ex`
- `lib/waw_trams/hourly_pattern.ex`

### Phase 2: Aggregation ✅ COMPLETE

Two aggregation mechanisms:

#### A. HourlyAggregator (Automatic)

GenServer that runs at minute 5 of each hour, aggregating the previous hour.

**File created:**
- `lib/waw_trams/hourly_aggregator.ex`

**Features:**
- Auto-starts with application (in supervision tree)
- Aggregates previous hour into daily_* tables (additive)
- Updates hourly_patterns (cumulative counters)
- Logs progress: `[HourlyAggregator] Aggregated 45 events for hour 2025-12-18 15:00`

**Manual trigger:**
```elixir
# In IEx
WawTrams.HourlyAggregator.aggregate_now()
WawTrams.HourlyAggregator.status()
```

#### B. Mix Task (Manual/Backfill)

For backfilling historical data or manual runs.

**File created:**
- `lib/mix/tasks/waw_trams.aggregate_daily.ex`

**Usage:**
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

### Phase 3: Query Migration ✅ COMPLETE

Update existing queries to use aggregated data + real-time additions.

**Tasks:**
- [x] Create `QueryRouter` module for smart data source routing
- [x] Update `hot_spots/1` — aggregated + events since :05
- [x] Update `impacted_lines/1` — aggregated + events since :05
- [x] Update `delays_by_hour/2` — aggregated + events since :05
- [x] Update `line_summary/2` — aggregated + events since :05
- [x] Update `heatmap_grid/0` — uses cumulative `HourlyPattern`
- [x] Update LiveViews to use `QueryRouter`

**File created:**
- `lib/waw_trams/query_router.ex`

**Strategy:** Aggregated data + real-time additions for consistent ~5min freshness:

```elixir
def hot_spots(opts) do
  aggregated = DailyIntersectionStat.hot_spots(to_date_opts(opts))
  
  if aggregated == [] do
    DelayEvent.hot_spots(opts)  # Fallback if no aggregated data
  else
    recent = get_recent_hot_spots()  # Events since :05
    merge_hot_spots(aggregated, recent)
  end
end
```

**Aggregated + Real-time (consistent freshness):**
- `hot_spots/1` — aggregated + events since :05
- `impacted_lines/1` — aggregated + events since :05
- `delays_by_hour/2` — aggregated + events since :05
- `line_summary/2` — aggregated + events since :05
- `heatmap_grid/0` — cumulative (all-time)

**Always raw (truly real-time):**
- `active/0` — live delays (currently happening)
- `recent/1` — recently resolved
- `stats/1` — 24h classification counts
- `line_hot_spots/2` — spatial clustering precision

### Phase 4: Cleanup Integration ✅ COMPLETE

Update cleanup task to work safely with aggregation.

**Tasks:**
- [x] Update `mix waw_trams.cleanup` to read `raw_retention_days` config
- [x] **Dry-run by default** — requires `--execute` to delete anything
- [x] **Aggregation check** — won't delete unaggregated dates
- [x] Detailed preview showing what would be deleted
- [x] Document recommended cron schedule

**Safety features:**
```bash
# Preview only (DEFAULT - no deletion)
mix waw_trams.cleanup

# Actually delete (requires explicit flag)
mix waw_trams.cleanup --execute

# Output shows:
#   📦 Aggregated (safe to delete): dates with ✓
#   ⚠️  NOT aggregated (would lose data): dates with ✗
```

**Recommended workflow:**
```bash
# 1. Aggregate first
mix waw_trams.aggregate_daily --backfill 7

# 2. Preview cleanup
mix waw_trams.cleanup

# 3. Execute if preview looks correct
mix waw_trams.cleanup --execute
```

**Cron setup (optional):**
```bash
# Aggregate at 00:05 daily
5 0 * * * cd /app && mix waw_trams.aggregate_daily

# Cleanup at 01:00 daily (manual review recommended initially)
# 0 1 * * * cd /app && mix waw_trams.cleanup --execute
```

### Phase 5: Dashboard Updates ⬜ (Optional/Future)

Add trend visualization using aggregated data.

**Tasks:**
- [ ] Add "Last 30 days" option to dashboard filters
- [ ] Add trend chart (delays over time) using `daily_line_stats`
- [ ] Add month-over-month comparison

---

## Testing Plan

1. **Unit tests** for aggregation logic (rounding, grouping)
2. **Integration test** for full aggregation cycle
3. **Comparison test**: Verify aggregated results match raw query results
4. **Performance test**: Benchmark queries before/after migration

## Rollback Plan

If issues arise:
1. Aggregated tables are additive (don't modify raw data)
2. Can revert query functions to use raw data only
3. Can re-run aggregation with `--backfill` if data is wrong

## Success Metrics

- [ ] `hot_spots` query < 50ms for 30d range (vs current ~500ms+)
- [ ] `heatmap_data` query < 10ms (vs current ~100ms)
- [ ] Storage stays under 50 MB/year
- [ ] Raw event cleanup runs without data loss

