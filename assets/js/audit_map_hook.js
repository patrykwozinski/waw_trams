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
    
    // Get currency from data attribute (PLN for EN, zł for PL)
    this.currency = this.el.dataset.currency || "PLN"
    
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
    
    // Track live delay bubbles (with ticking tooltips)
    this.liveDelays = new Map()  // vehicle_id -> { marker, startedAt, line }
    this.liveDelaysLayer = L.layerGroup().addTo(this.map)
    
    // Cost per second per tram (same as GlobalTickerHook)
    this.costPerSecond = (50 * 22 + 85) / 3600

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

    // NEW: Handle delay_started - add live ticking bubble
    this.handleEvent("delay_started", (delay) => {
      this.addLiveDelay(delay)
    })

    // NEW: Handle delay_resolved - explosion effect!
    this.handleEvent("delay_resolved", (data) => {
      this.removeLiveDelay(data.vehicle_id)
      this.createExplosion(data.lat, data.lon, data.line, data.duration, data.cost)
    })

    // Start the live tooltip updater
    this.startLiveTooltipUpdater()

    // Load initial active delays from data attribute
    this.loadInitialActiveDelays()

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

  // Load existing active delays on page load
  loadInitialActiveDelays() {
    try {
      const activeDelays = JSON.parse(this.el.dataset.activeDelays) || []
      console.log("Loading", activeDelays.length, "initial active delays")
      activeDelays.forEach(delay => this.addLiveDelay(delay))
    } catch (e) {
      console.error("Failed to parse initial active delays", e)
    }
  },

  // Add a live delay bubble with ticking tooltip
  addLiveDelay(delay) {
    const key = `${delay.lat}_${delay.lon}_${delay.started_at}`
    
    // Create pulsing live marker - compact: "L12 · 0s" on top, cost below
    const liveIcon = L.divIcon({
      className: "live-delay-marker",
      html: `<div class="live-delay-bubble" data-line="${delay.line}">
        <div class="live-top"><span class="live-line">L${delay.line}</span> · <span class="live-duration">0s</span></div>
        <span class="live-cost">0 PLN</span>
      </div>`,
      iconSize: [100, 50],
      iconAnchor: [50, 25],
    })

    const marker = L.marker([delay.lat, delay.lon], { 
      icon: liveIcon, 
      interactive: true,
      zIndexOffset: 1000  // Above other markers
    }).addTo(this.liveDelaysLayer)

    this.liveDelays.set(key, {
      marker,
      startedAt: delay.started_at,
      line: delay.line,
      lat: delay.lat,
      lon: delay.lon
    })
  },

  // Remove live delay when resolved
  removeLiveDelay(vehicleId) {
    // Find and remove by matching (we don't have vehicle_id in key, so find by proximity)
    // For now, just let it get cleaned up - the explosion replaces it
  },

  // Update all live delay tooltips every 100ms
  startLiveTooltipUpdater() {
    this.liveUpdateInterval = setInterval(() => {
      const now = Date.now()
      
      this.liveDelays.forEach((delay, key) => {
        const elapsedMs = now - delay.startedAt
        const elapsedSeconds = Math.floor(elapsedMs / 1000)
        const cost = (elapsedMs / 1000) * this.costPerSecond
        
        // Update the DOM inside the marker
        const bubble = delay.marker.getElement()?.querySelector('.live-delay-bubble')
        if (bubble) {
          bubble.querySelector('.live-duration').textContent = this.formatDuration(elapsedSeconds)
          bubble.querySelector('.live-cost').textContent = this.formatCostLive(cost)
        }
      })
    }, 100)
  },

  // EXPLOSION effect when delay resolves
  createExplosion(lat, lon, line, duration, cost) {
    // Remove any live delay marker at this location
    this.liveDelays.forEach((delay, key) => {
      if (Math.abs(delay.lat - lat) < 0.0001 && Math.abs(delay.lon - lon) < 0.0001) {
        delay.marker.remove()
        this.liveDelays.delete(key)
      }
    })

    // Create explosion rings (multiple expanding)
    for (let i = 0; i < 3; i++) {
      setTimeout(() => {
        const explosionIcon = L.divIcon({
          className: `explosion-ring explosion-ring-${i}`,
          iconSize: [200, 200],
          iconAnchor: [100, 100],
        })
        const explosionMarker = L.marker([lat, lon], { icon: explosionIcon, interactive: false }).addTo(this.map)
        
        setTimeout(() => explosionMarker.remove(), 1500)
      }, i * 100)
    }

    // Create final cost "receipt" that floats up - compact layout
    const receiptIcon = L.divIcon({
      className: "explosion-receipt",
      html: `<div class="receipt-content">
        <div class="receipt-top">L${line} · ${this.formatDuration(duration)}</div>
        <div class="receipt-cost">-${this.formatCostLive(cost)}</div>
      </div>`,
      iconSize: [120, 50],
      iconAnchor: [60, 25],
    })
    
    const receiptMarker = L.marker([lat, lon], { icon: receiptIcon, interactive: false }).addTo(this.map)
    
    // Float up and fade out
    setTimeout(() => receiptMarker.remove(), 3000)

    // Flash nearby intersection markers
    this.markersLayer.eachLayer((layer) => {
      const pos = layer.getLatLng()
      const dist = this.map.distance([lat, lon], pos)
      if (dist < 800) {
        const originalRadius = layer.options.radius
        const originalColor = layer.options.fillColor
        
        // Dramatic flash sequence
        layer.setStyle({ fillColor: "#fff", fillOpacity: 1 })
        layer.setRadius(originalRadius * 2)
        
        setTimeout(() => {
          layer.setStyle({ fillColor: "#ef4444", fillOpacity: 1 })
          layer.setRadius(originalRadius * 1.5)
        }, 100)
        
        setTimeout(() => {
          layer.setStyle({ fillColor: "#fbbf24", fillOpacity: 0.9 })
          layer.setRadius(originalRadius * 1.2)
        }, 200)
        
        setTimeout(() => {
          layer.setStyle({ fillColor: originalColor, fillOpacity: layer.options.fillOpacity })
          layer.setRadius(originalRadius)
        }, 500)
      }
    })
  },

  // Format cost with decimals for live ticking effect
  formatCostLive(amount) {
    const c = this.currency
    if (amount < 10) return `${amount.toFixed(2)} ${c}`
    if (amount < 100) return `${amount.toFixed(1)} ${c}`
    return `${Math.round(amount)} ${c}`
  },

  formatDuration(seconds) {
    if (!seconds) return ""
    if (seconds < 60) return `${seconds}s`
    const mins = Math.floor(seconds / 60)
    const secs = seconds % 60
    return secs > 0 ? `${mins}m ${secs}s` : `${mins}m`
  },

  formatCost(amount) {
    const c = this.currency
    if (amount >= 1000000) return `${(amount / 1000000).toFixed(1)}M ${c}`
    if (amount >= 1000) return `${(amount / 1000).toFixed(1)}k ${c}`
    return `${Math.round(amount)} ${c}`
  },

  destroyed() {
    if (this.liveUpdateInterval) {
      clearInterval(this.liveUpdateInterval)
    }
    if (this.map) {
      this.map.remove()
    }
  }
}

export default AuditMapHook

