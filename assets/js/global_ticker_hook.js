// Global Ticker Hook - Updates header numbers when delays resolve
// Numbers update on explosion (delay_resolved), not continuously

const GlobalTickerHook = {
  mounted() {
    this.baseCost = parseFloat(this.el.dataset.baseCost) || 0
    this.baseDelays = parseInt(this.el.dataset.baseDelays) || 0
    this.baseSeconds = parseInt(this.el.dataset.baseSeconds) || 0
    this.currency = this.el.dataset.currency || "PLN"
    
    // Display initial values
    this.updateDisplay()

    // Listen for delays resolving - this is when we update the header
    this.handleEvent("delay_resolved", (data) => {
      // Add resolved delay cost to running total with animation
      this.animateCostIncrease(data.cost)
    })
  },

  updated() {
    // Update base values when LiveView pushes new data
    this.baseCost = parseFloat(this.el.dataset.baseCost) || 0
    this.baseDelays = parseInt(this.el.dataset.baseDelays) || 0
    this.baseSeconds = parseInt(this.el.dataset.baseSeconds) || 0
    this.currency = this.el.dataset.currency || "PLN"
    
    // Re-display with new values
    this.updateDisplay()
  },

  updateDisplay() {
    this.updateCostDisplay(this.baseCost)
    this.updateTimeDisplay(this.baseSeconds)
    this.updateDelaysDisplay(this.baseDelays)
  },

  // Animate cost increase when delay resolves
  animateCostIncrease(addedCost) {
    const costEl = document.getElementById("ticker-cost")
    if (!costEl) return
    
    // Flash effect
    costEl.classList.add("cost-flash")
    setTimeout(() => costEl.classList.remove("cost-flash"), 600)
  },

  updateCostDisplay(cost) {
    const costEl = document.getElementById("ticker-cost")
    if (!costEl) return

    // Format with space as thousands separator: "3 620 PLN" or "3 620 zł"
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
  }
}

export default GlobalTickerHook

