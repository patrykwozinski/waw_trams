# Detection Logic

## Key Insight

**57% of tram-road intersections have a stop within 50m.** This means we can't classify delays as "traffic light" vs "boarding" in real-time. Instead:

1. Detect all unusual stops (time-based)
2. Persist to database with location
3. Analyze post-hoc which intersections accumulate the most delay

## Classification

```
Tram stopped (speed < 3 km/h):

├── AT TERMINAL (pętla, zajezdnia, P+R)
│   └── SKIP ─── normal layover behavior
│
├── AT REGULAR STOP (within 50m)
│   ├── < 180s  → normal_dwell (ignore)
│   └── > 180s  → blockage (persist) ← something is wrong
│
└── NOT AT STOP
    └── > 30s   → delay (persist) ← traffic/signal issue!
```

## Classifications

| Classification | Threshold | Location | Meaning |
|---------------|-----------|----------|---------|
| `delay` | > 30s | NOT at stop | Traffic/signal issue (gold!) |
| `blockage` | > 180s | AT stop | Abnormal dwell time |
| (ignored) | < 180s | AT stop | Normal boarding |
| (ignored) | any | AT terminal | Normal layover |

## Thresholds

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| Speed threshold | 3 km/h | Account for GPS drift |
| Stop proximity | 50m | Platform coverage |
| Intersection proximity | 50m | Crossing zone |
| Normal dwell | < 180s | Typical boarding time |
| Delay threshold | 30s | Filter GPS noise |

## Terminal Detection

Terminals are detected **per-line** using GTFS route data (172 unique line-stop pairs):

```
Line 25 at Pl. Narutowicza → terminal (skip delays)
Line 15 at Pl. Narutowicza → NOT terminal (detect delays)
```

**Why line-specific?** Some stops are terminals for certain lines but regular stops for others. The `line_terminals` table maps `(line, stop_id)` pairs extracted from GTFS `stop_times.txt` (first/last stops of each trip).

```bash
# Refresh terminal data from GTFS
mix waw_trams.import_line_terminals
```

Delays at line-specific terminals are ignored to prevent false positives from scheduled layovers.

## Example Logs

```
[DELAY] Vehicle V/17/5 (Line 17) stopped at (52.2297, 21.0122) - delay, at_stop: false, near_intersection: true
[RESOLVED] Vehicle V/17/5 (Line 17) moved after 45s - was: delay
```

## Post-hoc Analysis

The `delay` classification with `near_intersection: true` is the gold standard for identifying problematic intersections. These events indicate:

1. Tram stopped outside a platform
2. Near a known tram-road crossing
3. For more than 30 seconds

Aggregating these by location reveals which intersections cause the most cumulative delay — the target for transit priority advocacy.

