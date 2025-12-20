# Detection Logic

> **Audience:** Everyone — explains WHY we classify delays the way we do

## The Problem

**57% of tram-road intersections have a stop within 50m.** 

This means we can't classify delays as "traffic light" vs "boarding" in real-time — a tram stopped near both a platform and an intersection could be doing either.

## Our Approach

Instead of guessing in real-time, we:

1. **Detect** all unusual stops (time-based thresholds)
2. **Persist** to database with location metadata
3. **Analyze** post-hoc which intersections accumulate the most delay

## Classification Summary

| Where | Duration | Result |
|-------|----------|--------|
| At terminal | Any | ✅ Ignored (normal layover) |
| At stop | ≤ 3 min | ✅ Ignored (normal boarding) |
| At stop | > 3 min | 🔴 **Blockage** — something wrong |
| Not at stop | ≤ 30s | ✅ Ignored (brief/GPS noise) |
| Not at stop | > 30s | 🟠 **Delay** — traffic or signal issue |

> **For detailed thresholds**, see [Thresholds](thresholds.md).

## Duration Counting (Abnormal Time Only)

**We only count the ABNORMAL portion of a delay** — time beyond the threshold:

| Classification | Threshold | What we count |
|----------------|-----------|---------------|
| Delay | 30s | Time AFTER the first 30s |
| Blockage | 180s | Time AFTER the first 3 min |

**Example:**
- Tram stops at intersection for 90 seconds total
- First 30s = normal (ignored)
- Remaining 60s = counted as delay
- **Duration logged: 60s** (not 90s)

This ensures costs and statistics reflect only the *waste*, not normal operations.

**Why this matters:**
- Cost calculations use only abnormal time
- Statistics show actual excess delay
- Live tooltips tick from threshold, not from first stop

## Terminal Detection

Terminals are detected **per-line** using GTFS route data:

```
Line 25 at Pl. Narutowicza → terminal (skip)
Line 15 at Pl. Narutowicza → NOT terminal (detect)
```

This prevents false positives from scheduled layovers while still detecting delays at stops that are terminals for other lines.

## The Gold: `delay` + `near_intersection`

Events classified as `delay` (stopped >30s, not at a stop) that are also `near_intersection: true` are our primary target. These indicate:

1. Tram stopped outside a platform
2. Near a known tram-road crossing
3. For more than 30 seconds (abnormal)

Aggregating these by location reveals which intersections cause the most cumulative delay — **the target for transit priority advocacy**.

## Live Display

When viewing the map:

- **Active delays** show as pulsing bubbles with:
  - Intersection name (e.g., "Rondo ONZ")
  - Tram line (e.g., "L17")
  - Ticking cost (updates every 250ms)
  
- **Resolved delays** show a "cash-out" effect:
  - Bubble turns amber
  - Floats up and fades out
  - Final cost added to global counter

## Example Log Output

```
[DELAY] Vehicle V/17/5 (Line 17) stopped at Rondo ONZ - delay, at_stop: false, near_intersection: true
[RESOLVED] Vehicle V/17/5 (Line 17) moved after 45s - was: delay
```
