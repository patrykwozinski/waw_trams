# Clean Architecture Refactoring

> **Status:** Planning  
> **Priority:** Should complete before Audit Dashboard Phase 1  
> **Blocked by:** Nothing  
> **Blocks:** Audit Dashboard (cleaner foundation)

## Problem Statement

`DelayEvent` has grown to **736 lines** with mixed responsibilities:
- Schema definition
- CRUD operations
- Basic queries
- Complex analytics
- Aggregation helpers

This violates **Single Responsibility Principle** and makes:
- Testing harder (can't test analytics without DB)
- Navigation difficult ("where is hot_spots?")
- Adding features risky (touching god class)

---

## Target Architecture

```
lib/waw_trams/
├── delay_event.ex              # Schema + CRUD only
│
├── queries/                    # Read-only query modules
│   ├── active_delays.ex        # Real-time: active(), recent()
│   ├── hot_spots.ex            # Intersection clustering
│   ├── line_analysis.ex        # Line-specific queries
│   └── heatmap.ex              # Hour × Day patterns
│
├── analytics/                  # Computed metrics
│   ├── cost_calculator.ex      # Economic cost calculation
│   └── stats.ex                # Aggregated statistics
│
└── audit/                      # Audit Dashboard specific
    ├── leaderboard.ex          # Top N worst intersections
    ├── report_card.ex          # Single intersection detail
    └── summary.ex              # Header totals
```

---

## Module Responsibilities

### `WawTrams.DelayEvent` (Schema Only)

**Lines:** ~100  
**Responsibility:** Schema, changeset, basic CRUD

```elixir
defmodule WawTrams.DelayEvent do
  use Ecto.Schema
  import Ecto.Changeset
  
  schema "delay_events" do
    # fields...
  end
  
  def changeset/2
  def create/1
  def get/1
  def resolve/1
  def cleanup_orphaned/0
end
```

**Tests:** `test/waw_trams/delay_event_test.exs`
- Schema validation
- Create/resolve lifecycle
- Cleanup orphaned

---

### `WawTrams.Queries.ActiveDelays`

**Lines:** ~80  
**Responsibility:** Real-time delay queries

```elixir
defmodule WawTrams.Queries.ActiveDelays do
  def active()              # Unresolved delays
  def recent(limit \\ 100)  # Latest delays
  def count_active()        # For telemetry
  def count_today()         # For telemetry
  def resolved_since(since) # Recently resolved
end
```

**Tests:** `test/waw_trams/queries/active_delays_test.exs`
- Returns only unresolved
- Respects limit
- Count accuracy

---

### `WawTrams.Queries.HotSpots`

**Lines:** ~150  
**Responsibility:** Intersection clustering and ranking

```elixir
defmodule WawTrams.Queries.HotSpots do
  def clustered(opts \\ [])     # ST_ClusterDBSCAN grouping
  def summary(opts \\ [])        # Aggregate stats
  def for_line(line, opts \\ []) # Line-specific hot spots
end
```

**Tests:** `test/waw_trams/queries/hot_spots_test.exs`
- Clustering groups nearby points
- Summary aggregates correctly
- Line filter works

---

### `WawTrams.Queries.LineAnalysis`

**Lines:** ~120  
**Responsibility:** Line-specific delay patterns

```elixir
defmodule WawTrams.Queries.LineAnalysis do
  def summary(line, opts \\ [])        # Total delays, time lost
  def delays_by_hour(line, opts \\ []) # Hourly breakdown
  def worst_intersections(line, opts) # Hot spots for line
end
```

**Tests:** `test/waw_trams/queries/line_analysis_test.exs`
- Summary aggregates per line
- Hour breakdown is complete (0-23)
- Worst intersections sorted correctly

---

### `WawTrams.Queries.Heatmap`

**Lines:** ~80  
**Responsibility:** Hour × Day patterns

```elixir
defmodule WawTrams.Queries.Heatmap do
  def data(opts \\ [])           # Raw hour/day/count
  def grid(opts \\ [])           # 24×7 matrix with intensities
  def for_intersection(id, opts) # Single intersection heatmap
end
```

**Tests:** `test/waw_trams/queries/heatmap_test.exs`
- Grid is 24×7
- Intensities calculated correctly
- Intersection filter works

---

### `WawTrams.Analytics.CostCalculator`

**Lines:** ~60  
**Responsibility:** Economic cost calculation (pure functions)

```elixir
defmodule WawTrams.Analytics.CostCalculator do
  @config %{
    vot_pln_per_hour: 22,
    driver_wage_pln_per_hour: 80,
    energy_pln_per_hour: 5,
    passengers: %{peak: 150, offpeak: 50, night: 10}
  }
  
  def calculate(delay_seconds, hour)
  def passenger_cost(delay_seconds, hour)
  def operational_cost(delay_seconds)
  def breakdown(delay_seconds, hour)  # Returns map with components
end
```

**Tests:** `test/waw_trams/analytics/cost_calculator_test.exs`
- Peak vs off-peak vs night passengers
- Operational cost constant
- Breakdown sums to total
- Edge cases (0 seconds, negative)

---

### `WawTrams.Analytics.Stats`

**Lines:** ~80  
**Responsibility:** Aggregated statistics

```elixir
defmodule WawTrams.Analytics.Stats do
  def for_period(since, until \\ nil)  # Classification breakdown
  def multi_cycle_count(opts \\ [])    # Priority failures
  def total_time_lost(opts \\ [])      # Sum of durations
end
```

**Tests:** `test/waw_trams/analytics/stats_test.exs`
- Period filtering works
- Multi-cycle count matches flag
- Time lost aggregates correctly

---

### `WawTrams.Audit.*` (New for Audit Dashboard)

Created during Audit Dashboard Phase 1. See [audit_dashboard.md](audit_dashboard.md).

---

## Migration Plan

### Phase 1: Extract Queries (No Breaking Changes)
**Effort:** 2-3 hours

1. Create `lib/waw_trams/queries/` directory
2. Extract `ActiveDelays` module
3. Extract `HotSpots` module
4. Keep old functions in `DelayEvent` as **delegates**
5. Add deprecation warnings to old functions
6. Create tests for new modules

```elixir
# In DelayEvent - temporary delegates
def active do
  IO.warn("DelayEvent.active/0 is deprecated, use Queries.ActiveDelays.active/0")
  Queries.ActiveDelays.active()
end
```

**Deliverable:** New modules work, old code still works

---

### Phase 2: Extract Analytics
**Effort:** 1-2 hours

1. Create `lib/waw_trams/analytics/` directory
2. Extract `CostCalculator` (new, for Audit)
3. Extract `Stats` module
4. Add delegates with deprecation warnings
5. Create tests

**Deliverable:** Cost calculation ready, stats isolated

---

### Phase 3: Extract Line Analysis & Heatmap
**Effort:** 1-2 hours

1. Extract `LineAnalysis` module
2. Extract `Heatmap` module
3. Add delegates with deprecation warnings
4. Create tests

**Deliverable:** All query modules extracted

---

### Phase 4: Update Callers
**Effort:** 2-3 hours

1. Update `DashboardLive` to use new modules
2. Update `MapLive` to use new modules
3. Update `LineLive` to use new modules
4. Update `HeatmapLive` to use new modules
5. Update `QueryRouter` to use new modules
6. Update `HourlyAggregator` to use new modules

**Deliverable:** All callers use new modules

---

### Phase 5: Remove Delegates
**Effort:** 30 minutes

1. Remove deprecated delegate functions from `DelayEvent`
2. Run full test suite
3. Verify no warnings

**Deliverable:** Clean `DelayEvent` (~100 lines)

---

## Test Coverage Requirements

| Module | Test File | Min Tests |
|--------|-----------|-----------|
| `DelayEvent` | `delay_event_test.exs` | 10 (existing, keep) |
| `Queries.ActiveDelays` | `queries/active_delays_test.exs` | 5 |
| `Queries.HotSpots` | `queries/hot_spots_test.exs` | 6 |
| `Queries.LineAnalysis` | `queries/line_analysis_test.exs` | 5 |
| `Queries.Heatmap` | `queries/heatmap_test.exs` | 4 |
| `Analytics.CostCalculator` | `analytics/cost_calculator_test.exs` | 8 |
| `Analytics.Stats` | `analytics/stats_test.exs` | 4 |

**Total new tests:** ~32

---

## File Size Targets

| File | Current | Target |
|------|---------|--------|
| `delay_event.ex` | 736 | **~100** |
| `queries/active_delays.ex` | - | ~80 |
| `queries/hot_spots.ex` | - | ~150 |
| `queries/line_analysis.ex` | - | ~120 |
| `queries/heatmap.ex` | - | ~80 |
| `analytics/cost_calculator.ex` | - | ~60 |
| `analytics/stats.ex` | - | ~80 |

---

## Success Criteria

- [ ] `DelayEvent` is ≤150 lines
- [ ] All new modules have tests
- [ ] No deprecation warnings in logs
- [ ] All existing tests pass
- [ ] `mix credo` passes (no complexity warnings)
- [ ] Dashboard/Map/Line/Heatmap pages work unchanged

---

## Timeline

| Phase | Effort | Dependency |
|-------|--------|------------|
| **Phase 1:** Extract Queries | 2-3h | None |
| **Phase 2:** Extract Analytics | 1-2h | Phase 1 |
| **Phase 3:** Extract Line/Heatmap | 1-2h | Phase 1 |
| **Phase 4:** Update Callers | 2-3h | Phases 1-3 |
| **Phase 5:** Remove Delegates | 30m | Phase 4 |

**Total:** ~8 hours (1 day)

---

## Decision Log

| Decision | Rationale |
|----------|-----------|
| Keep delegates temporarily | Zero breaking changes during migration |
| Queries vs Analytics split | Queries = DB reads, Analytics = computed/derived |
| Audit namespace separate | Feature-specific, may have different lifecycle |
| Tests per module | Isolated testing, clear coverage |

---

## Open Questions

1. Should `QueryRouter` move to `queries/` or stay in root?
2. Should we use behaviours for query modules (standardize interface)?
3. Config injection - Application config or module attributes?

