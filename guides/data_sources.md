# Data Sources & Ingestion

This project relies on two primary external data sources: ZTM (Real-time) and OpenStreetMap (Infrastructure).

## 1. Traffic Signals (OpenStreetMap)

We fetch traffic signal locations from OpenStreetMap using the Overpass API.
Since this data changes rarely, we treat it as static seed data.

### The Query
To update the `intersections.csv` file, run this query at [Overpass Turbo](https://overpass-turbo.eu/).

```c
/* Goal: Find intersections between Tram Tracks and Car Roads in Warsaw.
  Target Area: Warsaw Bounding Box.
*/
[out:json][timeout:180][bbox:52.09, 20.85, 52.37, 21.28];

// 1. Get Tram Tracks
way["railway"="tram"]->.trams;

// 2. Get Car Roads (excluding pedestrian paths)
way["highway"]["highway"!~"^(footway|cycleway|path|steps|service)$"]->.roads;

// 3. Find Intersections (Nodes shared by both)
node(w.trams)(w.roads);

out geom;
```

### Import Process
1. Export the result as GeoJSON.
2. Convert to CSV using jq.
3. Run the mix task:
```sh
mix waw_trams.import_intersections
```
