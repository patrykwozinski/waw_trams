# Thresholds & Configuration

**For validation with Tramwaje Warszawskie**

All configurable values used in delay detection. See [Detection Logic](detection_logic.md) for the reasoning behind our approach.

---

## 1. Speed Detection

| Parameter | Value | Unit | Rationale |
|-----------|-------|------|-----------|
| **Stopped threshold** | **3.0** | km/h | Below this = "stopped". Accounts for GPS drift. |

**❓ Question:** Is 3 km/h appropriate? Should we use 1-2 km/h?

---

## 2. Spatial Proximity

| Parameter | Value | Unit | Usage |
|-----------|-------|------|-------|
| **Stop proximity** | **50** | meters | "At a stop" if within this distance |
| **Intersection proximity** | **50** | meters | "Near intersection" if within this distance |
| **Terminal proximity** | **75** | meters | Line-specific terminal check (includes approach) |
| **Clustering radius** | **55** | meters | Group nearby delay points as one intersection |

**❓ Questions:**
- Is 50m enough for long platforms?
- Should intersection radius be larger (75m) for approach zones?

---

## 3. Time Thresholds

### At a Stop (Platform)

| Duration | Classification | Persisted? |
|----------|---------------|------------|
| ≤ 180s (3 min) | `normal_dwell` | ❌ No |
| > 180s | `blockage` | ✅ Yes |

**❓ Question:** What's the max normal dwell at busy stops (Centrum, Ratusz)?

### NOT at a Stop

| Duration | Classification | Persisted? |
|----------|---------------|------------|
| ≤ 30s | `brief_stop` | ❌ No |
| > 30s | `delay` | ✅ Yes |

**❓ Question:** What's the typical signal cycle time at major intersections?

### At Terminal

| Duration | Classification | Persisted? |
|----------|---------------|------------|
| Any | — | ❌ No (always ignored) |

---

## 4. System Parameters

| Parameter | Value | Unit | Purpose |
|-----------|-------|------|---------|
| **Poll interval** | 10 | seconds | GTFS-RT feed refresh |
| **Worker timeout** | 300 | seconds | Terminate idle tram process |
| **Position history** | 10 | positions | Speed calculation buffer |

---

## 5. Decision Flow

```
Position Update (10s)
       │
       ▼
  Speed < 3 km/h? ──No──▶ Moving (clear delay state)
       │
      Yes
       ▼
  At Terminal? ──Yes──▶ Ignore (normal layover)
  (line-specific)
       │
      No
       ▼
  At Stop? ──Yes──▶ Duration > 180s? ──Yes──▶ 🔴 BLOCKAGE
  (50m)              │
       │            No ──▶ Ignore (normal boarding)
      No
       ▼
  Duration > 30s? ──Yes──▶ 🟠 DELAY ← Target!
       │
      No ──▶ Ignore (brief/GPS noise)
```

---

## 6. Questions for Tramwaje Warszawskie

### Threshold Validation
1. **Speed (3 km/h):** Appropriate for "stopped" detection?
2. **Stop radius (50m):** Covers all platform lengths?
3. **Dwell time (180s):** What indicates a problem at a stop?
4. **Signal delay (30s):** Typical red phase duration?

### Operational Data
5. Signal cycle times at key intersections?
6. Known problem intersections?
7. Dispatcher alert thresholds?
8. Seasonal/time-of-day patterns?

### Data Quality
9. Sample GPS traces for validation?
10. Known GPS dead zones?

---

## 7. Code References

```elixir
# lib/waw_trams/tram_worker.ex
@speed_threshold_kmh 3.0
@idle_timeout_ms 5 * 60 * 1000

# lib/waw_trams/stop.ex
def near_stop?(lat, lon, radius_meters \\ 50)

# lib/waw_trams/intersection.ex
def near_intersection?(lat, lon, radius_meters \\ 50)

# lib/waw_trams/tram_worker.ex - classify_delay/2
180  # seconds at stop → blockage
30   # seconds not at stop → delay
```

---

**Project:** Warsaw Tram Priority Auditor  
**Goal:** Identify intersections causing systematic delays for transit priority advocacy  
**Data:** GTFS-RT (mkuran.pl) + OpenStreetMap intersections
