# Performance & Optimization

> **Audience:** Developers optimizing or scaling the application
>
> **Goal:** Document all performance optimizations for $5/month hosting

This guide covers the strategies used to make the app performant at scale while keeping costs minimal.

---

## Design Goals

| Goal | Target |
|------|--------|
| Hosting cost | **$5/month** (Fly.io/Render/Railway) |
| Concurrent users | **100-500** without degradation |
| Page load | **< 100ms** (after cache warm) |
| Real-time updates | **Instant** (< 50ms) |

---

## 1. Query Caching (ETS)

Built-in Erlang Term Storage — **zero external dependencies**.

### Cache TTLs

| Page | Query | TTL | Rationale |
|------|-------|-----|-----------|
| Audit | `stats` | 30s | Balance freshness vs load |
| Audit | `leaderboard` | 60s | Expensive spatial clustering |
| Dashboard | `impacted_lines` | 30s | Matches refresh interval |

### Impact

| Metric | Without Cache | With Cache | Improvement |
|--------|---------------|------------|-------------|
| Queries/min (100 users) | ~7,800 | ~60 | **99% reduction** |
| Avg query time | ~100ms | ~0ms (hit) | **Instant** |

### Cache Invalidation

- **Automatic TTL expiry** — entries cleaned every 60s
- **Manual invalidation** — when HourlyAggregator runs
- **Race-safe** — handles startup before ETS table exists

```elixir
# Usage
WawTrams.Cache.get_audit_stats(since: since)
WawTrams.Cache.get_audit_leaderboard(limit: 20)
WawTrams.Cache.get_dashboard_impacted_lines(limit: 10)
WawTrams.Cache.invalidate_all()
```

---

## 2. Aggregated Data Strategy

Raw `delay_events` grow ~14k/day. Complex queries on raw data become slow.

### Solution: Hourly Aggregation

| Table | Purpose | Query Time |
|-------|---------|------------|
| `hourly_intersection_stats` | Pre-aggregated stats + cost | **10-20ms** |
| `delay_events` (raw) | Only last 7 days | N/A (backup) |

### Query Performance Comparison

| Query | Raw Events | Aggregated | Speedup |
|-------|------------|------------|---------|
| `hot_spots` | 338ms | 10ms | **33x** |
| `hot_spot_summary` | 167ms | 2ms | **79x** |
| `leaderboard` | 150ms | 21ms | **7x** |

### Partial Day Filtering

Queries properly handle DateTime boundaries:

```sql
-- Filters aggregated data by (date, hour) for accuracy
WHERE (date > $1 OR (date = $1 AND hour >= $2))
```

---

## 3. Thundering Herd Prevention

When many users are connected, periodic refreshes can overwhelm the database if they all fire simultaneously.

### Solution: Jittered Timers

```elixir
# Instead of all users refreshing at exactly 5:00:00...
jitter = :rand.uniform(@refresh_jitter_max)
Process.send_after(self(), :refresh, @refresh_interval_base + jitter)
```

| Page | Refresh Interval | Jitter |
|------|------------------|--------|
| Audit | 5 minutes | 0-30 seconds |
| Dashboard | 30 seconds | 0-5 seconds |

**Result:** Queries spread evenly over time instead of spiking.

---

## 4. TramWorker Spatial Cache

Each tram worker caches spatial query results to avoid repeated database hits.

### What's Cached

| Query | When Cached | Invalidated |
|-------|-------------|-------------|
| `at_stop?` | First stop check | When tram moves |
| `near_intersection?` | First stop check | When tram moves |
| `at_terminal?` | First stop check | When tram moves |

### DB Calls Per Position Update

| Scenario | DB Calls |
|----------|----------|
| Moving | 1 (resolve delay if active) |
| Stopped (first check) | 3 (spatial queries, then cached) |
| Stopped (subsequent) | 0 (using cache) |
| Creating delay | 1 (insert) |

---

## 5. Real-Time Updates (PubSub + Client-Side)

Live updates bypass cache and database entirely.

### Flow

```
Delay Created (threshold exceeded)
       │
       ▼
Phoenix.PubSub.broadcast("delays", {:delay_created, event})
       │
       ▼
LiveView receives → push_event("delay_started", {...})
       │
       ▼
JS: Add live bubble to map + start ticking cost
       │
       ▼
JS: Global counter includes active delay costs (ticks every 250ms)
```

```
Delay Resolved (tram moves)
       │
       ▼
Phoenix.PubSub.broadcast("delays", {:delay_resolved, event})
       │
       ▼
LiveView receives → push_event("delay_resolved", {...})
       │
       ▼
JS: "Cash-out" animation (amber, float up, fade)
       │
       ▼
JS: Remove from active delays, update base cost
```

### What's Updated Live

| Data | Method | Latency |
|------|--------|---------|
| Map bubbles | JS push_event | **Instant** |
| Bubble cost | JS interval (250ms) | **250ms** |
| Global counter | JS interval (250ms) | **250ms** |
| Leaderboard | Debounced DB query | **3s** |

### Client-Side Cost Calculation

The JS hooks calculate cost identically to the server:

```javascript
// Same formula as CostCalculator.calculate/2
costPerSecond = (50 * 22 + 85) / 3600  // ~0.39 PLN/s
```

This allows the UI to tick without any server round-trips.

---

## 6. Database Configuration

### Connection Pool

```elixir
# config/runtime.exs
pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5")
```

| Environment | Pool Size | Rationale |
|-------------|-----------|-----------|
| Development | 10 | Fast local queries |
| Production ($5) | 5 | Budget DB limits |
| Production (scaled) | 10-20 | If needed |

### Indexes

Key indexes for spatial queries:

| Table | Index | Purpose |
|-------|-------|---------|
| `stops` | `geom` (GIST) | `ST_DWithin` proximity |
| `intersections` | `geom` (GIST) | `ST_DWithin` proximity |
| `hourly_intersection_stats` | `(date, hour, lat, lon)` | Unique constraint + lookup |

---

## 7. Capacity Planning

### Current Load Profile

| Component | Load | Notes |
|-----------|------|-------|
| Poller | 1 HTTP req/10s | External GTFS-RT |
| TramWorkers | ~150-200 processes | In-memory |
| HourlyAggregator | 1 heavy query/hour | Off-peak |
| LiveView | ~50KB/connection | WebSocket |

### Estimated Capacity

| Users | Memory | DB Queries/min | Status |
|-------|--------|----------------|--------|
| 10 | ~5MB | ~10 | ✅ Easy |
| 100 | ~50MB | ~60 | ✅ Good |
| 500 | ~250MB | ~300 | ✅ Manageable |
| 1000 | ~500MB | ~600 | ⚠️ Near limit |

### Scaling Options

If you need more capacity:

1. **Increase cache TTL** — Less freshness, more capacity
2. **Add read replica** — Separate DB for queries
3. **Static page for viral traffic** — Pre-rendered snapshot
4. **Upgrade to $10/month** — 2x resources

---

## 8. Monitoring

### Cache Stats

```elixir
WawTrams.Cache.cache_stats()
# => %{size: 12, hits: 450, misses: 23}
```

### Key Metrics to Watch

| Metric | Warning | Critical |
|--------|---------|----------|
| Cache hit rate | < 90% | < 50% |
| Query time (avg) | > 100ms | > 500ms |
| Memory usage | > 400MB | > 500MB |
| DB connections | > 4 | = 5 (pool full) |

---

## Code References

```elixir
# lib/waw_trams/cache.ex
@audit_stats_ttl_ms 30_000
@audit_leaderboard_ttl_ms 60_000
@dashboard_ttl_ms 30_000

# lib/waw_trams_web/live/audit_live.ex
@refresh_interval_base :timer.minutes(5)
@refresh_jitter_max :timer.seconds(30)
@leaderboard_debounce_ms 3_000  # Real-time leaderboard updates

# lib/waw_trams_web/live/dashboard_live.ex
@refresh_interval_base 30_000
@refresh_jitter_max 5_000
```

