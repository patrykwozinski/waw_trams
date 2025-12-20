import L from "leaflet"

// Fix Leaflet's default icon paths (broken by bundlers)
delete L.Icon.Default.prototype._getIconUrl
L.Icon.Default.mergeOptions({
  iconRetinaUrl: "https://unpkg.com/leaflet@1.9.4/dist/images/marker-icon-2x.png",
  iconUrl: "https://unpkg.com/leaflet@1.9.4/dist/images/marker-icon.png",
  shadowUrl: "https://unpkg.com/leaflet@1.9.4/dist/images/marker-shadow.png",
})

const AuditMapHook = {
  mounted() {
    // Warsaw center
    const center = [52.2297, 21.0122]
    
    // Initialize map
    this.map = L.map(this.el, {
      center: center,
      zoom: 12,
    })

    // Add OpenStreetMap tiles (dark theme)
    L.tileLayer("https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png", {
      attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> &copy; <a href="https://carto.com/">CARTO</a>',
      maxZoom: 19,
    }).addTo(this.map)

    // Store markers layer
    this.markersLayer = L.layerGroup().addTo(this.map)
    this.selectedMarker = null

    // Handle leaderboard data from server
    this.handleEvent("leaderboard_data", ({ data }) => {
      this.renderIntersections(data)
    })

    // Handle fly_to event for smooth map animation
    this.handleEvent("fly_to", ({ lat, lon }) => {
      this.map.flyTo([lat, lon], 15, { duration: 1.5 })
      // Find and highlight the marker at this location
      this.markersLayer.eachLayer((layer) => {
        const latLng = layer.getLatLng()
        if (Math.abs(latLng.lat - lat) < 0.0001 && Math.abs(latLng.lng - lon) < 0.0001) {
          this.highlightMarker(layer, lat, lon)
        }
      })
    })

    // Handle reset_view event to zoom out to show all markers
    this.handleEvent("reset_view", () => {
      console.log("reset_view: resetting map view")
      // Clear selection highlight
      if (this.selectedMarker) {
        this.selectedMarker.setStyle({ weight: 2, color: "#0f0f0f" })
        this.selectedMarker = null
      }
      // Always reset to Warsaw center with default zoom
      this.map.flyTo([52.2297, 21.0122], 12, { duration: 0.8 })
    })

    // Handle pulse event for real-time delay notifications
    this.handleEvent("pulse", ({ lat, lon }) => {
      this.createPulse(lat, lon)
    })

    // Request initial data
    this.pushEvent("request_leaderboard", {})
  },

  renderIntersections(data) {
    // Clear existing markers
    this.markersLayer.clearLayers()

    // Find max cost for scaling
    const maxCost = Math.max(...data.map(d => d.cost?.total || 0), 1)

    data.forEach((spot, index) => {
      const rank = index + 1
      const costRatio = (spot.cost?.total || 0) / maxCost
      
      // SIZE based on rank (top spots bigger)
      const radius = rank <= 3 ? 18 : rank <= 10 ? 14 : 10

      // COLOR: simple red gradient based on cost
      const opacity = 0.4 + costRatio * 0.5  // 0.4 to 0.9

      const marker = L.circleMarker([spot.lat, spot.lon], {
        radius: radius,
        fillColor: "#ef4444",  // red-500, same for all
        color: "#1f2937",
        weight: 1.5,
        opacity: 1,
        fillOpacity: opacity,
      })

      // Click handler
      marker.on("click", () => {
        this.pushEvent("select_intersection", { lat: spot.lat.toString(), lon: spot.lon.toString() })
        this.highlightMarker(marker, spot.lat, spot.lon)
      })

      // Simple hover tooltip for all markers
      const stopName = spot.location_name || "Unknown"
      const cost = this.formatCost(spot.cost?.total || 0)
      const tooltipContent = `
        <div style="text-align: center; padding: 4px 8px;">
          <div style="font-size: 10px; color: #9ca3af; margin-bottom: 2px;">#${rank}</div>
          <div style="font-size: 12px; font-weight: 500; color: #e5e7eb; max-width: 160px;">${stopName}</div>
          <div style="color: #f87171; font-size: 13px; font-weight: 600; margin-top: 3px;">${cost}</div>
        </div>
      `
      marker.bindTooltip(tooltipContent, { 
        direction: "top", 
        offset: [0, -radius],
        className: "subtle-tooltip"
      })

      this.markersLayer.addLayer(marker)
    })

    // Fit bounds if we have data
    if (data.length > 0) {
      const bounds = L.latLngBounds(data.map(s => [s.lat, s.lon]))
      this.map.fitBounds(bounds, { padding: [50, 50], maxZoom: 14 })
    }
  },

  highlightMarker(marker, lat, lon) {
    // Remove previous highlight
    if (this.selectedMarker) {
      this.selectedMarker.setStyle({ weight: 2, color: "#0f0f0f" })
    }

    // Highlight selected
    marker.setStyle({ weight: 4, color: "#fff" })
    this.selectedMarker = marker

    // Zoom to marker (zoom level 16 for street-level detail)
    this.map.flyTo([lat, lon], 16, { animate: true, duration: 0.8 })
  },

  createPulse(lat, lon) {
    // Create expanding ring animation at the delay location
    const pulseIcon = L.divIcon({
      className: "pulse-marker",
      iconSize: [150, 150],
      iconAnchor: [75, 75],
    })

    const pulseMarker = L.marker([lat, lon], { icon: pulseIcon, interactive: false }).addTo(this.map)

    // Remove after animation completes
    setTimeout(() => {
      pulseMarker.remove()
    }, 2500)

    // Flash nearby markers more dramatically
    this.markersLayer.eachLayer((layer) => {
      const pos = layer.getLatLng()
      const dist = this.map.distance([lat, lon], pos)
      if (dist < 800) {
        // Within 800m - dramatic pulse effect
        const originalRadius = layer.options.radius
        const originalColor = layer.options.fillColor
        
        // Flash white then back to red
        layer.setStyle({ fillColor: "#fff", fillOpacity: 1 })
        layer.setRadius(originalRadius * 1.5)
        
        setTimeout(() => {
          layer.setStyle({ fillColor: "#fbbf24", fillOpacity: 0.9 }) // amber flash
          layer.setRadius(originalRadius * 1.3)
        }, 150)
        
        setTimeout(() => {
          layer.setStyle({ fillColor: originalColor, fillOpacity: layer.options.fillOpacity })
          layer.setRadius(originalRadius)
        }, 400)
      }
    })
  },

  formatCost(amount) {
    if (amount >= 1000000) return `${(amount / 1000000).toFixed(1)}M PLN`
    if (amount >= 1000) return `${(amount / 1000).toFixed(1)}k PLN`
    return `${Math.round(amount)} PLN`
  },

  destroyed() {
    if (this.map) {
      this.map.remove()
    }
  }
}

export default AuditMapHook

