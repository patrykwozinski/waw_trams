# Warsaw Signal Timing & Detection Improvements

Based on validated data from Warsaw traffic signal operations.

## Background: Warsaw Signal Parameters

| Parameter | Value | Impact on Detection |
|-----------|-------|---------------------|
| Standard Cycle | **120s** | Delays >120s = missed multiple cycles |
| Night Cycle | 90-100s | Shorter waits expected at night |
| Typical Red | **80-100s** | Normal wait if no priority |
| Max Green (Priority) | 30-45s | Priority extension limit |
| Min Green | 8-12s | Minimum crossing window |

## Problem #1: Double Stop Trap 🔴 CRITICAL

### The Issue

Many Warsaw stops have a traffic light **immediately after** the platform (within 20-60m). This creates a pattern:

```
Timeline:
0s    - Tram arrives at PLATFORM, doors open
20s   - Doors close, tram accelerates
25s   - Tram stops at RED LIGHT (20m ahead)
85s   - Light turns green, tram departs
```

### Current Behavior (Wrong)

Our system sees TWO separate events:
1. `normal_dwell` at platform (20s) - correctly ignored
2. `delay` at light (60s) - correctly detected

**This is actually correct!** ✅ We only count the light delay, not the platform dwell.

### Real Problem: Rapid Re-Stop

The actual issue is when the tram:
1. Stops at platform (detected as potential delay)
2. Moves briefly (delay "resolved")
3. Immediately stops at light (NEW delay created)

If both stops exceed thresholds, we count **two delays** for what's really **one journey interruption**.

```
Current (Wrong):
  DELAY #1: Platform stop, 35s → resolved when tram moves
  DELAY #2: Light stop, 60s → new delay created
  Total: 2 events, 95s recorded separately

Should be:
  DELAY #1: Merged stop, 95s total
  Total: 1 event, captures full interruption
```

### Solution: Merge Consecutive Stops

When a delay is "resolved" (tram moves), don't immediately close the event. Instead:

1. **Grace Period:** Wait 45 seconds before finalizing
2. **Distance Check:** If tram stops again within 60m, extend the original delay
3. **Final Resolution:** Only resolve when tram has moved >60m AND stayed moving for >45s

### Implementation

```elixir
# TramWorker state additions
%{
  # ... existing fields ...
  pending_resolution: nil,  # {delay_id, resolved_at, position}
}

# On tram movement (potential resolution)
# Instead of immediately resolving:
#   DelayEvent.resolve(delay_id)
# 
# Set pending:
#   pending_resolution: {delay_id, now, {lat, lon}}

# On next stop detection:
# If within 60m and <45s of pending_resolution:
#   - Cancel the pending resolution
#   - Continue the original delay (don't create new)
# Else:
#   - Finalize the pending resolution
#   - Start new delay if needed
```

---

## Problem #2: Multi-Cycle Detection 🟡 ENHANCEMENT

### The Issue

A delay of 30s might be normal (caught one red). A delay of **150s** means the tram missed **two full signal cycles** - clear evidence of priority system failure.

### Current Behavior

All delays >30s are classified the same:
- 35s delay = `delay`
- 150s delay = `delay`

### Solution: Add Severity Classification

| Duration | Classification | Meaning |
|----------|---------------|---------|
| 30-120s | `delay` | Single cycle wait |
| >120s | `delay` + `multi_cycle: true` | Priority failure |

### Implementation

Add `multi_cycle` boolean field to `delay_events`:
- Set `true` when `duration_seconds > 120`
- Use for filtering/highlighting in dashboard

---

## Problem #3: Priority Type Analysis 🟢 FUTURE

### The Concept

By analyzing delay durations at intersections, we can infer which priority mode is active:

| Avg Delay | Likely Priority Mode |
|-----------|---------------------|
| 5-15s | Green Extension working |
| 20-40s | Red Truncation working |
| 80-100s | No priority (full red wait) |

### Implementation (Future)

Post-hoc analysis query:
```sql
SELECT 
  nearest_stop,
  AVG(duration_seconds) as avg_delay,
  CASE 
    WHEN AVG(duration_seconds) < 20 THEN 'green_extension'
    WHEN AVG(duration_seconds) < 50 THEN 'red_truncation'
    ELSE 'no_priority'
  END as inferred_mode
FROM delay_events
WHERE near_intersection = true
GROUP BY nearest_stop
```

---

## Implementation Phases

### Phase 1: Double Stop Merge ✅ COMPLETE
- [x] Add `pending_resolution` state to TramWorker
- [x] Implement grace period logic (45s, 60m)
- [x] Add tests for merge scenarios
- [x] Verify existing tests still pass (111 tests, 0 failures)

### Phase 2: Multi-Cycle Flag ✅ COMPLETE
- [x] Add migration for `multi_cycle` boolean
- [x] Update `DelayEvent.resolve` to set flag when:
  - Duration > 120s AND
  - Near intersection OR not at stop (excludes pure boarding blockages)
- [x] Add `multi_cycle_count/1` query function
- [x] Update dashboard: legend, stats card (purple ⚡), resolved list highlighting
- [x] Add tests (9 tests covering all multi_cycle scenarios)

### Phase 3: Priority Analysis (Future)
- [ ] Add analysis query
- [ ] Add to line analysis page
- [ ] Consider intersection-level recommendations

---

## References

- Warsaw ITS documentation (internal)
- Signal timing parameters validated with TW operations

