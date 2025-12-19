# Audit Dashboard — Project Specification

> **Status:** Planning  
> **Route:** `/audit`  
> **Replaces:** `/map` and `/heatmap` (after completion)  
> **Depends on:** [Clean Architecture Refactor](clean_architecture.md) (Phase 1-2)

## Vision

Transform raw delay data into an **Infrastructure Report Card** — a political tool that proves exactly *where* and *how much* money is being wasted on failed tram priority systems.

**Goal:** Enable activists, journalists, and city officials to identify, quantify, and share evidence of infrastructure failures.

---

## Core Concept

### The Story We're Telling

> "Warsaw wasted **1.2 Million PLN** on tram delays this month.  
> Here are the 10 worst intersections. Click any to see the evidence."

### User Journey

1. **Overview:** Land on page → See map covered in red/yellow dots → Sidebar shows "Top 10 Worst"
2. **Hunt:** Scan leaderboard → Find familiar location ranked #3
3. **Drill Down:** Click → Map zooms → Sidebar transforms into Report Card
4. **Evidence:** See grade, cost, worst times, multi-cycle failures
5. **Share:** Screenshot Report Card → Post on social media

---

## Layout

### Desktop: Split-Screen

```
┌─────────────────────────────────────────────────────────────────┐
│  HEADER: "Total Time Lost: 4,500h  |  Economic Cost: 1.2M PLN"  │
│  [ Last 7 Days ▼ ]  [ All Lines ▼ ]                             │
├───────────────────────────────────────────┬─────────────────────┤
│                                           │                     │
│                                           │   INTELLIGENCE      │
│              MAP                          │      PANEL          │
│         (Crime Map)                       │                     │
│                                           │   - Leaderboard     │
│    ● ● ●     ●                            │     OR              │
│      ●   ● ●                              │   - Report Card     │
│        ●       ●                          │                     │
│                                           │                     │
└───────────────────────────────────────────┴─────────────────────┘
```

### Mobile: Tab Navigation

```
┌─────────────────────────┐
│  [ 🗺️ Map | 📊 List | 📋 Detail ]  │
├─────────────────────────┤
│                         │
│   (Active Tab Content)  │
│                         │
└─────────────────────────┘
```

---

## Components

### Zone A: Header

**Purpose:** Set the emotional tone with big, shocking numbers.

| Element | Description |
|---------|-------------|
| **Total Time Lost** | Sum of all delay durations in period (e.g., "4,500 hours") |
| **Economic Cost** | Time × Passengers × VoT in PLN (e.g., "1.2M PLN") |
| **Date Filter** | Dropdown: Last 24h, 7 days, 30 days, Custom |
| **Line Filter** | Dropdown: All lines, or specific line |

### Zone B: Crime Map

**Purpose:** Visual overview of problem areas.

| Element | Description |
|---------|-------------|
| **Base Map** | OpenStreetMap tiles (same as current /map) |
| **Circles** | One per intersection cluster |
| **Circle Size** | Proportional to **Total Duration** (bigger = worse) |
| **Circle Color** | Based on severity (see Color Scale below) |
| **Interaction** | Click → Select intersection → Update sidebar |
| **Zoom** | Clicking leaderboard item flies map to location |

**Color Scale (Simplified — No Pass Rate):**

| Color | Condition | Meaning |
|-------|-----------|---------|
| 🔴 Red | >50% delays are `multi_cycle` | Priority system failure |
| 🟠 Orange | 20-50% delays are `multi_cycle` | Inconsistent |
| 🟡 Yellow | <20% delays are `multi_cycle` | Occasional issues |

### Zone C: Intelligence Panel

**Purpose:** Contextual data that changes based on selection.

#### State 1: City Leaderboard (Default)

Shown when no intersection is selected.

```
┌─────────────────────────────────┐
│  🔥 TOP 10 WORST INTERSECTIONS  │
├─────────────────────────────────┤
│  1. Rondo ONZ        -45,000 PLN│
│  2. Plac Zawiszy     -38,000 PLN│
│  3. Rondo Dmowskiego -31,000 PLN│
│  ...                            │
└─────────────────────────────────┘
```

| Column | Data |
|--------|------|
| Rank | By total economic cost |
| Name | Nearest stop name (existing logic) |
| Cost | Negative PLN (the "damage") |

**Interaction:** Click row → Select intersection → Fly map → Show Report Card

#### State 2: Report Card (Selected Intersection)

Shown when an intersection is selected.

```
┌─────────────────────────────────┐
│  ← Back to Leaderboard          │
├─────────────────────────────────┤
│  📍 RONDO ONZ                   │
│  Near: Rondo ONZ 01             │
├─────────────────────────────────┤
│  💰 COST: -45,000 PLN           │
│  ⏱️ TIME LOST: 180 hours        │
│  🚨 DELAYS: 847                 │
│  ⚡ MULTI-CYCLE: 423 (50%)      │
├─────────────────────────────────┤
│  📊 WHEN IT FAILS               │
│  ┌─────────────────────────┐    │
│  │  (Mini Heatmap 24x7)    │    │
│  │  Hour × Day of Week     │    │
│  └─────────────────────────┘    │
├─────────────────────────────────┤
│  🚋 AFFECTED LINES              │
│  1, 4, 15, 18, 35               │
├─────────────────────────────────┤
│  [ 🔗 Google Maps ]             │
└─────────────────────────────────┘
```

---

## Economic Cost Calculation

### Formula

```
Total Cost = Passenger Cost + Operational Cost

Passenger Cost = Delay_Hours × Passengers × Value_of_Time
Operational Cost = Delay_Hours × (Driver_Wage + Energy_Cost)
```

### Parameters (Configurable)

#### Passenger Time Cost

| Parameter | Value | Source |
|-----------|-------|--------|
| **Value of Time (VoT)** | 22 PLN/hour | Polish commuter weighted average |
| **Peak Passengers** (7-9, 15-18) | 150 | Pesa Jazz packed capacity |
| **Off-Peak Passengers** (9-15, 18-22) | 50 | Moderate load |
| **Night Passengers** (22-7) | 10 | Minimal |

#### Operational Cost (Company Direct Cost)

| Parameter | Value | Source |
|-----------|-------|--------|
| **Driver Wage** | 80 PLN/hour | Full employer cost (incl. ZUS/taxes) |
| **Energy (Idling)** | 5 PLN/hour | ~5 kW × ~1 PLN/kWh (HVAC, lights, computers) |
| **Total Operational** | **85 PLN/hour** | Per tram, regardless of passengers |

### Cost Breakdown Example

A **10-minute delay** during **morning peak** (150 passengers):

| Component | Calculation | Cost |
|-----------|-------------|------|
| Passenger time | 0.167h × 150 × 22 PLN | **550 PLN** |
| Driver wage | 0.167h × 80 PLN | **13 PLN** |
| Energy | 0.167h × 5 PLN | **1 PLN** |
| **TOTAL** | | **564 PLN** |

Same delay at **night** (10 passengers):

| Component | Calculation | Cost |
|-----------|-------------|------|
| Passenger time | 0.167h × 10 × 22 PLN | **37 PLN** |
| Driver wage | 0.167h × 80 PLN | **13 PLN** |
| Energy | 0.167h × 5 PLN | **1 PLN** |
| **TOTAL** | | **51 PLN** |

### Implementation

```elixir
@config %{
  vot_pln_per_hour: 22,
  driver_wage_pln_per_hour: 80,
  energy_pln_per_hour: 5,
  passengers_peak: 150,
  passengers_offpeak: 50,
  passengers_night: 10
}

def calculate_cost(delay_seconds, hour) do
  hours = delay_seconds / 3600
  passengers = passenger_estimate(hour)
  
  passenger_cost = hours * passengers * @config.vot_pln_per_hour
  operational_cost = hours * (@config.driver_wage_pln_per_hour + @config.energy_pln_per_hour)
  
  passenger_cost + operational_cost
end

defp passenger_estimate(hour) when hour in 7..8, do: @config.passengers_peak
defp passenger_estimate(hour) when hour in 15..17, do: @config.passengers_peak
defp passenger_estimate(hour) when hour in 9..14, do: @config.passengers_offpeak
defp passenger_estimate(hour) when hour in 18..21, do: @config.passengers_offpeak
defp passenger_estimate(_hour), do: @config.passengers_night
```

### Display in UI

Header could show breakdown on hover/click:

```
💰 Total Cost: 1.2M PLN
   ├── 👥 Passenger time: 1.1M PLN (92%)
   ├── 🧑‍✈️ Driver wages: 85K PLN (7%)
   └── ⚡ Energy: 12K PLN (1%)
```

---

## Data Requirements

### New Queries Needed

| Query | Purpose | Source |
|-------|---------|--------|
| `intersection_summary/1` | Stats for single intersection | `delay_events` + aggregated |
| `intersection_leaderboard/1` | Top N by cost | `daily_intersection_stats` |
| `intersection_heatmap/2` | Hour×Day grid for one intersection | `delay_events` |
| `total_cost/1` | Sum of all costs in period | Calculated |

### Existing Data (Reusable)

| Data | Source | Notes |
|------|--------|-------|
| Intersection clusters | `hot_spots/1` | Already clusters by ~55m |
| Nearest stop names | `hot_spots/1` | Already included |
| Multi-cycle count | `delay_events.multi_cycle` | ✅ Ready |
| Affected lines | `hot_spots/1` | Already included |

---

## Implementation Phases

### Phase 1: Data Layer & Cost Calculation
**Effort:** 1-2 days

- [ ] Add `calculate_cost/2` function with passenger heuristics
- [ ] Add `intersection_summary/2` query (single intersection stats)
- [ ] Add `intersection_heatmap/3` query (hour×day for one intersection)
- [ ] Add `total_stats/1` query (header numbers)
- [ ] Update `hot_spots` to include cost calculation
- [ ] Tests for cost calculation

**Deliverable:** All data available via `WawTrams.Audit.*` modules

---

### Phase 2: Basic Layout & Map
**Effort:** 2-3 days

- [ ] Create `/audit` route with `AuditLive`
- [ ] Split-screen layout (desktop)
- [ ] Header with big numbers and filters
- [ ] Map component with sized/colored circles
- [ ] Circle click → select intersection
- [ ] Mobile: Tab navigation structure

**Deliverable:** Working map with clickable circles, empty sidebar

---

### Phase 3: Leaderboard Panel
**Effort:** 1 day

- [ ] Leaderboard component (default state)
- [ ] Top 10 worst intersections by cost
- [ ] Click row → fly map to location
- [ ] Click row → select intersection

**Deliverable:** Functional leaderboard with map interaction

---

### Phase 4: Report Card Panel
**Effort:** 2 days

- [ ] Report Card component (selected state)
- [ ] Back button to return to leaderboard
- [ ] Stats display (cost, time, delays, multi-cycle)
- [ ] Mini heatmap (24×7 grid) for selected intersection
- [ ] Affected lines list
- [ ] Google Maps link

**Deliverable:** Complete intersection detail view

---

### Phase 5: Polish & Mobile
**Effort:** 1-2 days

- [ ] Map fly animation on selection
- [ ] Loading states
- [ ] Empty states
- [ ] Mobile tab navigation (Map / List / Detail)
- [ ] Responsive breakpoints
- [ ] Translations (PL/EN)

**Deliverable:** Production-ready feature

---

### Phase 6: Cleanup
**Effort:** 0.5 day

- [ ] Remove `/map` route
- [ ] Remove `/heatmap` route  
- [ ] Update navigation
- [ ] Update README

**Deliverable:** Single unified audit page

---

## Technical Architecture

### LiveView Structure

```
AuditLive (parent)
├── State: selected_intersection_id, date_range, line_filter
├── MapComponent (Zone B)
│   └── Leaflet map with circles
└── SidebarComponent (Zone C)
    ├── LeaderboardComponent (when selected == nil)
    └── ReportCardComponent (when selected != nil)
        └── MiniHeatmapComponent
```

### Events Flow

```
User clicks circle on map
  → MapComponent sends {:select_intersection, id}
  → AuditLive updates selected_intersection_id
  → SidebarComponent re-renders as ReportCard
  
User clicks leaderboard row
  → LeaderboardComponent sends {:select_intersection, id}
  → AuditLive updates selected_intersection_id
  → MapComponent receives new selection, flies to location
  → SidebarComponent re-renders as ReportCard

User clicks "Back"
  → ReportCardComponent sends :deselect
  → AuditLive sets selected_intersection_id = nil
  → SidebarComponent re-renders as Leaderboard
```

---

## Success Metrics

| Metric | Target |
|--------|--------|
| Time to first insight | < 5 seconds |
| Clicks to evidence | ≤ 2 (land → click → report card) |
| Screenshot-worthy | Report Card fits in one screen |
| Load time | < 1 second |

---

## Future Enhancements (Post-MVP)

| Feature | Description |
|---------|-------------|
| **Pass Rate Grades** | A/C/F based on % of trams delayed |
| **Priority Mode Inference** | Detect if intersection uses Green Extension, Red Truncation, or No Priority based on avg delay patterns |
| **Trend Arrows** | ↑↓ compared to previous period |
| **Export PDF** | Generate report card as PDF |
| **Share Link** | `/audit?intersection=123` deep link |
| **Comparison Mode** | Compare two intersections side-by-side |
| **Time Animation** | Play through 24 hours on map |

### Priority Mode Inference (Future)

By analyzing average delay durations, we can infer which priority mode is active:

| Avg Delay | Likely Priority Mode |
|-----------|---------------------|
| 5-15s | Green Extension working |
| 20-40s | Red Truncation working |
| 80-100s | No priority (full red wait) |

Could be shown in Report Card as: "Inferred Priority: **Red Truncation** (avg 32s)"

---

## Questions for Later

1. Should we track total trams passing (not just delayed) for accurate pass rates?
2. Should Report Card include historical trend chart?
3. Should we add "Report this intersection" button (generate email to ZTM)?

