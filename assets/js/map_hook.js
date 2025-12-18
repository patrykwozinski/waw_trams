import L from "leaflet"
import "leaflet.markercluster"

// Fix Leaflet's default icon paths (broken by bundlers)
delete L.Icon.Default.prototype._getIconUrl
L.Icon.Default.mergeOptions({
  iconRetinaUrl: "https://unpkg.com/leaflet@1.9.4/dist/images/marker-icon-2x.png",
  iconUrl: "https://unpkg.com/leaflet@1.9.4/dist/images/marker-icon.png",
  shadowUrl: "https://unpkg.com/leaflet@1.9.4/dist/images/marker-shadow.png",
})

const MapHook = {
  mounted() {
    // Warsaw center
    const center = [52.2297, 21.0122]
    
    // Initialize map
    this.map = L.map(this.el, {
      center: center,
      zoom: 12,
    })

    // Add OpenStreetMap tiles
    L.tileLayer("https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png", {
      attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>',
      maxZoom: 19,
    }).addTo(this.map)

    // Create marker cluster group with custom styling
    this.markersLayer = L.markerClusterGroup({
      maxClusterRadius: 50,
      spiderfyOnMaxZoom: true,
      showCoverageOnHover: false,
      zoomToBoundsOnClick: true,
      iconCreateFunction: (cluster) => {
        const count = cluster.getChildCount()
        const size = count < 5 ? 'small' : count < 10 ? 'medium' : 'large'
        const sizes = { small: 30, medium: 40, large: 50 }
        
        return L.divIcon({
          html: `<div style="
            background: linear-gradient(135deg, #ef4444, #f97316);
            color: white;
            border-radius: 50%;
            width: ${sizes[size]}px;
            height: ${sizes[size]}px;
            display: flex;
            align-items: center;
            justify-content: center;
            font-weight: bold;
            font-size: ${size === 'large' ? 14 : 12}px;
            border: 3px solid #1f2937;
            box-shadow: 0 2px 8px rgba(0,0,0,0.3);
          ">${count}</div>`,
          className: 'marker-cluster-custom',
          iconSize: L.point(sizes[size], sizes[size])
        })
      }
    }).addTo(this.map)

    // Handle hot spots data from server
    this.handleEvent("hot_spots", ({ spots }) => {
      this.renderHotSpots(spots)
    })

    // Request initial data
    this.pushEvent("request_hot_spots", {})
  },

  renderHotSpots(spots) {
    // Clear existing markers
    this.markersLayer.clearLayers()

    spots.forEach((spot, index) => {
      // Size based on delay count (min 10, max 30)
      const radius = Math.min(30, Math.max(10, spot.delay_count * 3))
      
      // Color based on rank
      const color = index < 3 ? "#ef4444" : index < 7 ? "#f97316" : "#eab308"

      const marker = L.circleMarker([spot.lat, spot.lon], {
        radius: radius,
        fillColor: color,
        color: "#1f2937",
        weight: 2,
        opacity: 1,
        fillOpacity: 0.7,
      })

      // Popup with details
      const popupContent = `
        <div style="min-width: 150px;">
          <div style="font-weight: bold; margin-bottom: 4px;">
            #${index + 1} Hot Spot
          </div>
          <div style="color: #666; font-size: 12px; margin-bottom: 8px;">
            (${spot.lat.toFixed(4)}, ${spot.lon.toFixed(4)})
          </div>
          <div style="display: flex; justify-content: space-between; margin-bottom: 4px;">
            <span>Delays:</span>
            <strong style="color: #ef4444;">${spot.delay_count}</strong>
          </div>
          <div style="display: flex; justify-content: space-between; margin-bottom: 4px;">
            <span>Total time:</span>
            <strong>${this.formatDuration(spot.total_delay_seconds)}</strong>
          </div>
          <div style="display: flex; justify-content: space-between; margin-bottom: 8px;">
            <span>Avg:</span>
            <strong>${spot.avg_delay_seconds}s</strong>
          </div>
          <div style="font-size: 11px; color: #666;">
            Lines: ${spot.affected_lines.join(", ")}
          </div>
        </div>
      `
      
      marker.bindPopup(popupContent)
      this.markersLayer.addLayer(marker)
    })

    // Fit bounds if we have spots
    if (spots.length > 0) {
      const bounds = L.latLngBounds(spots.map(s => [s.lat, s.lon]))
      this.map.fitBounds(bounds, { padding: [50, 50], maxZoom: 14 })
    }
  },

  formatDuration(seconds) {
    if (seconds < 60) return `${seconds}s`
    if (seconds < 3600) {
      const mins = Math.floor(seconds / 60)
      const secs = seconds % 60
      return `${mins}m ${secs}s`
    }
    const hours = Math.floor(seconds / 3600)
    const mins = Math.floor((seconds % 3600) / 60)
    return `${hours}h ${mins}m`
  },

  destroyed() {
    if (this.map) {
      this.map.remove()
    }
  }
}

export default MapHook

