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
| Not at stop | 30s – 120s | 🟠 **Delay** — single signal cycle |
| Not at stop | > 120s | ⚡ **Delay + Multi-Cycle** — priority failure |

### Multi-Cycle Flag (Priority Failures)

Warsaw intersections use 120-second signal cycles. If a tram waits **>120s near an intersection**, it means the tram missed multiple green phases — clear evidence of broken transit priority.

**Key:** `multi_cycle` is ONLY set when `near_intersection = true`. Long delays at stops without nearby intersections are boarding issues, not signal failures.

| Scenario | near_intersection | Duration | multi_cycle |
|----------|-------------------|----------|-------------|
| Stop near intersection | ✅ | 150s | ⚡ Yes |
| Stop far from intersection | ❌ | 150s | ❌ No |
| Intersection (no stop) | ✅ | 150s | ⚡ Yes |

> **For detailed thresholds and validation questions**, see [Thresholds](thresholds.md).

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
3. For more than 30 seconds

Aggregating these by location reveals which intersections cause the most cumulative delay — **the target for transit priority advocacy**.

## Example Log Output

```
[DELAY] Vehicle V/17/5 (Line 17) stopped at (52.2297, 21.0122) - delay, at_stop: false, near_intersection: true
[RESOLVED] Vehicle V/17/5 (Line 17) moved after 45s - was: delay
```
