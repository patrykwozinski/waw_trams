# Warsaw Signal Timing & Detection Improvements

> **Audience:** Developers implementing signal-aware features
>
> **Related:** [Thresholds](thresholds.md) for configurable values, [Detection Logic](detection_logic.md) for classification rules

Based on validated data from Warsaw traffic signal operations.

## Background: Warsaw Signal Parameters

| Parameter | Value | Impact on Detection |
|-----------|-------|---------------------|
| Standard Cycle | **120s** | Delays >120s = missed multiple cycles |
| Night Cycle | 90-100s | Shorter waits expected at night |
| Typical Red | **80-100s** | Normal wait if no priority |
| Max Green (Priority) | 30-45s | Priority extension limit |
| Min Green | 8-12s | Minimum crossing window |

## Multi-Cycle Detection ✅ IMPLEMENTED

A delay of 30s might be normal (caught one red). A delay of **150s** means the tram missed **two full signal cycles** — clear evidence of priority system failure.

| Duration | Classification | Meaning |
|----------|---------------|---------|
| 30-120s | `delay` | Single cycle wait |
| >120s | `delay` + `multi_cycle: true` | Priority failure |

The `multi_cycle` flag is set automatically when:
- Duration > 120s AND
- Near intersection OR not at stop (excludes pure boarding delays)

Dashboard shows ⚡ indicator for multi-cycle delays.

---

## Priority Type Analysis 🟢 FUTURE

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

## Implementation Status

### Multi-Cycle Flag ✅ COMPLETE
- [x] Add migration for `multi_cycle` boolean
- [x] Update `DelayEvent.resolve` to set flag when duration > 120s at intersection
- [x] Add `multi_cycle_count/1` query function
- [x] Update dashboard: legend, stats card (purple ⚡), resolved list highlighting

### Priority Type Analysis 🔮 FUTURE
- [ ] Infer priority mode from average delay durations
- [ ] Add to line analysis page
- [ ] Generate intersection-level recommendations

---

## References

- Warsaw ITS documentation (internal)
- Signal timing parameters validated with TW operations

