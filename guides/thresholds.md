# Detection Thresholds & Business Logic

**Document for validation with Tramwaje Warszawskie**

This document describes all configurable thresholds and business rules used to detect and classify tram delays in the Warsaw Tram Priority Auditor system.

---

## 1. Speed Detection

| Parameter | Value | Unit | Rationale |
|-----------|-------|------|-----------|
| **Stopped threshold** | **3.0** | km/h | Tram is considered "stopped" when moving slower than this. Accounts for GPS drift and creeping movement at signals. |

**Question for TW:** Is 3 km/h appropriate? Should we use a lower threshold (e.g., 1-2 km/h) to be more precise?

---

## 2. Spatial Proximity

| Parameter | Value | Unit | Rationale |
|-----------|-------|------|-----------|
| **Stop proximity** | **50** | meters | Distance from tram to nearest stop platform to consider it "at a stop" |
| **Intersection proximity** | **50** | meters | Distance from tram to nearest tram-road intersection |
| **Terminal proximity** | **50** | meters | Distance to check if tram is at a line-specific terminal |
| **Clustering radius** | **30** | meters | Nearby intersection nodes are grouped as one physical location |

**Question for TW:** 
- Is 50m appropriate for stop detection? Some platforms are long.
- Should intersection detection use a larger radius (e.g., 75m) to account for approach zones?

---

## 3. Time-Based Classification

### 3.1 At a Regular Stop (Platform)

| Duration | Classification | Action | Rationale |
|----------|---------------|--------|-----------|
| 0 – 180s | `normal_dwell` | **Ignored** | Normal passenger boarding/alighting time |
| > 180s | `blockage` | **Logged** | Abnormally long stop — potential incident |

**Question for TW:** 
- Is 180 seconds (3 minutes) the right threshold for "something is wrong"?
- What's the typical maximum dwell time at busy stops (e.g., Centrum, Ratusz)?

### 3.2 NOT at a Stop (In Traffic / At Signal)

| Duration | Classification | Action | Rationale |
|----------|---------------|--------|-----------|
| 0 – 30s | `brief_stop` | **Ignored** | GPS noise, brief signal wait |
| > 30s | `delay` | **Logged** | Signal/traffic delay — this is what we want to detect! |

**Question for TW:**
- Is 30 seconds appropriate for signal delay detection?
- What's the typical signal cycle time at major intersections?

### 3.3 At a Terminal (Pętla, Zajezdnia)

| Duration | Classification | Action | Rationale |
|----------|---------------|--------|-----------|
| Any | — | **Always ignored** | Normal layover between trips |

**Implementation detail:** Terminals are detected per-line using GTFS data. Example: Pl. Narutowicza is a terminal for line 25 but a regular stop for line 15.

---

## 4. Data Polling

| Parameter | Value | Unit | Rationale |
|-----------|-------|------|-----------|
| **Position update interval** | **10** | seconds | GTFS-RT feed refresh rate |
| **Worker idle timeout** | **300** | seconds | Tram process terminated if no updates (end of service) |

**Data source:** mkuran.pl GTFS-Realtime feed (community-maintained, cleaner than raw ZTM API)

---

## 5. Detection Flow Diagram

```
Tram Position Update (every 10s)
         │
         ▼
    Speed < 3 km/h?
         │
    ┌────┴────┐
    │ NO      │ YES
    │         ▼
    │    At Terminal?
    │    (line-specific)
    │         │
    │    ┌────┴────┐
    │    │ YES     │ NO
    │    │         ▼
    │    │    At Stop?
    │    │    (within 50m)
    │    │         │
    │    │    ┌────┴────┐
    │    │    │ YES     │ NO
    │    │    ▼         ▼
    │    │  Duration?  Duration?
    │    │    │         │
    │    │  ≤180s     ≤30s
    │    │    │ normal   │ brief
    │    │    │ (ignore) │ (ignore)
    │    │    │         │
    │    │  >180s     >30s
    │    │    │         │
    │    │    ▼         ▼
    │    │ BLOCKAGE   DELAY ← Gold!
    │    │    │         │
    │    └────┴────┬────┘
    │              │
    │         Log + Track
    │              │
    └──────────────┴──────────────────▶ Continue monitoring
```

---

## 6. Classification Summary

| Classification | Location | Duration | Persisted | Meaning |
|----------------|----------|----------|-----------|---------|
| `normal_dwell` | At stop | ≤ 180s | ❌ No | Normal boarding |
| `blockage` | At stop | > 180s | ✅ Yes | Something wrong at stop |
| `brief_stop` | Not at stop | ≤ 30s | ❌ No | GPS noise / brief wait |
| `delay` | Not at stop | > 30s | ✅ Yes | **Traffic/signal issue** |
| — | At terminal | Any | ❌ No | Normal layover |

---

## 7. Questions for Tramwaje Warszawskie

### Thresholds
1. **Speed threshold (3 km/h):** Is this appropriate for detecting stopped trams?
2. **Stop proximity (50m):** Does this cover all platform lengths?
3. **Normal dwell time (180s):** What's the expected maximum boarding time at busy stops?
4. **Signal delay threshold (30s):** What's the typical red phase duration at major intersections?

### Operational Context
5. Do you have data on typical signal cycle times at key intersections?
6. Are there specific intersections known to cause regular delays?
7. What dwell time would indicate a problem requiring dispatcher attention?
8. Are there seasonal/time-of-day variations we should account for?

### Data Validation
9. Can you provide sample GPS traces to validate our speed calculation?
10. Are there known GPS dead zones where position data is unreliable?

---

## 8. Configurable Values (Code References)

```elixir
# lib/waw_trams/tram_worker.ex
@speed_threshold_kmh 3.0        # Speed below which tram is "stopped"
@idle_timeout_ms 5 * 60 * 1000  # 5 minutes without updates = end of service

# lib/waw_trams/stop.ex
radius_meters \\ 50             # Default proximity for stop detection

# lib/waw_trams/intersection.ex  
radius_meters \\ 50             # Default proximity for intersection detection

# lib/waw_trams/tram_worker.ex - classify_delay/2
180                             # Seconds at stop before "blockage"
30                              # Seconds not at stop before "delay"
```

---

## 9. Contact

**Project:** Warsaw Tram Priority Auditor  
**Purpose:** Identify intersections causing systematic delays to support transit priority advocacy  
**Data Source:** GTFS-RT via mkuran.pl + OpenStreetMap intersection data

---

*Document generated from codebase analysis. All thresholds are configurable.*

