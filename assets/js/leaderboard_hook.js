/**
 * LeaderboardHook - Smooth FLIP animations for leaderboard reordering
 * 
 * Uses the FLIP (First, Last, Invert, Play) animation technique to smoothly
 * animate items when they change position in the leaderboard.
 */
const LeaderboardHook = {
  mounted() {
    this.positions = new Map()
    this.recordPositions()
  },

  beforeUpdate() {
    // FIRST: Record current positions before DOM update
    this.recordPositions()
  },

  updated() {
    // LAST & INVERT & PLAY: Animate from old positions to new
    this.animateReorder()
  },

  recordPositions() {
    const items = this.el.querySelectorAll('[data-leaderboard-item]')
    this.positions.clear()
    
    items.forEach(item => {
      const id = item.dataset.leaderboardItem
      const rect = item.getBoundingClientRect()
      this.positions.set(id, {
        top: rect.top,
        left: rect.left,
        height: rect.height
      })
    })
  },

  animateReorder() {
    const items = this.el.querySelectorAll('[data-leaderboard-item]')
    
    items.forEach(item => {
      const id = item.dataset.leaderboardItem
      const oldPos = this.positions.get(id)
      
      if (!oldPos) {
        // New item - fade in
        item.style.opacity = '0'
        item.style.transform = 'translateX(-20px)'
        
        requestAnimationFrame(() => {
          item.style.transition = 'opacity 300ms ease-out, transform 300ms ease-out'
          item.style.opacity = '1'
          item.style.transform = 'translateX(0)'
          
          item.addEventListener('transitionend', () => {
            item.style.transition = ''
            item.style.opacity = ''
            item.style.transform = ''
          }, { once: true })
        })
        return
      }
      
      const newRect = item.getBoundingClientRect()
      const deltaY = oldPos.top - newRect.top
      
      if (Math.abs(deltaY) < 2) return // No significant movement
      
      // INVERT: Apply inverse transform to make it appear at old position
      item.style.transform = `translateY(${deltaY}px)`
      item.style.transition = 'none'
      
      // Force reflow
      item.offsetHeight
      
      // PLAY: Animate to final position
      requestAnimationFrame(() => {
        item.style.transition = 'transform 400ms cubic-bezier(0.4, 0, 0.2, 1)'
        item.style.transform = 'translateY(0)'
        
        // Highlight items that moved up
        if (deltaY > 10) {
          item.classList.add('leaderboard-moved-up')
          setTimeout(() => {
            item.classList.remove('leaderboard-moved-up')
          }, 1500)
        }
        
        item.addEventListener('transitionend', () => {
          item.style.transition = ''
          item.style.transform = ''
        }, { once: true })
      })
    })
    
    // Record new positions for next update
    this.recordPositions()
  }
}

export default LeaderboardHook

