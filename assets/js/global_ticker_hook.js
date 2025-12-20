// Global Ticker Hook - LIVE ticking counter including active delays
// The Big Number includes the cost of all currently stuck trams, ticking up in real-time

const GlobalTickerHook = {
  mounted() {
    this.baseCost = parseFloat(this.el.dataset.baseCost) || 0
    this.baseDelays = parseInt(this.el.dataset.baseDelays) || 0
    this.baseSeconds = parseInt(this.el.dataset.baseSeconds) || 0
    this.currency = this.el.dataset.currency || "PLN"
    
    // Track active delays for live ticking
    this.activeDelays = new Map()  // vehicle_id -> { startedAt }
    
    // Cost per second per tram (same as AuditMapHook)
    // (50 passengers × 22 PLN/h + 85 PLN/h operational) / 3600
    this.costPerSecond = (50 * 22 + 85) / 3600
    
    // Load initial active delays
    this.loadInitialActiveDelays()
    
    // Start live ticker
    this.startTicker()

    // Listen for new delays starting
    this.handleEvent("delay_started", (data) => {
      this.activeDelays.set(data.vehicle_id || `${data.lat}_${data.lon}`, {
        startedAt: data.started_at
      })
    })

    // Listen for delays resolving - flash effect + remove from active
    this.handleEvent("delay_resolved", (data) => {
      this.activeDelays.delete(data.vehicle_id)
      this.animateCostFlash()
    })
  },
  
  loadInitialActiveDelays() {
    try {
      const delays = JSON.parse(this.el.dataset.activeDelays || "[]")
      delays.forEach(d => {
        this.activeDelays.set(d.vehicle_id || `${d.lat}_${d.lon}`, {
          startedAt: d.started_at
        })
      })
    } catch (e) {
      // Ignore parse errors
    }
  },

  startTicker() {
    // Tick every 250ms - same cadence as map tooltips
    this.tickerInterval = setInterval(() => this.tick(), 250)
  },
  
  tick() {
    const now = Date.now()
    
    // Calculate cost of all active delays RIGHT NOW
    let activeCost = 0
    let activeSeconds = 0
    
    this.activeDelays.forEach((delay) => {
      const elapsedMs = now - delay.startedAt
      const elapsedSec = elapsedMs / 1000
      activeSeconds += elapsedSec
      activeCost += elapsedSec * this.costPerSecond
    })
    
    // Total = resolved delays (base) + active delays (live)
    const totalCost = this.baseCost + activeCost
    const totalSeconds = this.baseSeconds + activeSeconds
    const totalDelays = this.baseDelays + this.activeDelays.size
    
    this.updateCostDisplay(totalCost)
    this.updateTimeDisplay(totalSeconds)
    this.updateDelaysDisplay(totalDelays)
  },

  updated() {
    // Update base values when LiveView pushes new data
    this.baseCost = parseFloat(this.el.dataset.baseCost) || 0
    this.baseDelays = parseInt(this.el.dataset.baseDelays) || 0
    this.baseSeconds = parseInt(this.el.dataset.baseSeconds) || 0
    this.currency = this.el.dataset.currency || "PLN"
    
    // Reload active delays in case they changed
    this.loadInitialActiveDelays()
  },

  // Flash effect when a delay resolves (cost "locks in")
  animateCostFlash() {
    const costEl = document.getElementById("ticker-cost")
    if (!costEl) return
    
    costEl.classList.add("cost-flash")
    setTimeout(() => costEl.classList.remove("cost-flash"), 600)
  },

  updateCostDisplay(cost) {
    const costEl = document.getElementById("ticker-cost")
    if (!costEl) return

    // Format with space as thousands separator: "3 620 zł"
    const rounded = Math.round(cost)
    const formatted = rounded.toString().replace(/\B(?=(\d{3})+(?!\d))/g, " ")
    costEl.textContent = `${formatted} ${this.currency}`
  },

  updateTimeDisplay(totalSeconds) {
    const timeEl = document.getElementById("ticker-time")
    if (!timeEl) return

    const hours = Math.floor(totalSeconds / 3600)
    const mins = Math.floor((totalSeconds % 3600) / 60)
    const secs = Math.floor(totalSeconds % 60)

    let display
    if (hours > 0) {
      display = `${hours}h ${mins}m`
    } else if (mins > 0) {
      display = `${mins}m ${secs}s`
    } else {
      display = `${secs}s`
    }
    
    timeEl.textContent = display
  },

  updateDelaysDisplay(count) {
    const delaysEl = document.getElementById("ticker-delays")
    if (!delaysEl) return
    
    // Format with space as thousands separator
    delaysEl.textContent = count.toString().replace(/\B(?=(\d{3})+(?!\d))/g, " ")
  },
  
  destroyed() {
    if (this.tickerInterval) {
      clearInterval(this.tickerInterval)
    }
  }
}

export default GlobalTickerHook

