// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import topbar from "../vendor/topbar"

const Hooks = {}

Hooks.IngestionCountdown = {
  mounted() {
    this.start()
  },
  updated() {
    this.start()
  },
  destroyed() {
    this.stop()
  },
  start() {
    this.stop()
    const deadline = this.el.getAttribute("data-deadline")
    if (!deadline) return
    this.deadline = new Date(deadline)
    if (isNaN(this.deadline)) return
    this.tick()
    this.timer = setInterval(() => this.tick(), 1000)
  },
  stop() {
    if (this.timer) {
      clearInterval(this.timer)
      this.timer = null
    }
  },
  tick() {
    if (!this.deadline) return
    const diff = this.deadline - new Date()
    if (diff <= 0) {
      this.el.textContent = "expired"
      this.stop()
      return
    }
    const minutes = Math.floor(diff / 60000)
    const seconds = Math.floor((diff % 60000) / 1000)
    this.el.textContent = `${minutes}:${String(seconds).padStart(2, "0")}`
  }
}

Hooks.CopyInvitationLink = {
  mounted() {
    this.handleClick = async event => {
      // Let the server event still run, but ensure we handle the UI/clipboard here.
      event.preventDefault()

      const inputId = this.el.getAttribute("data-target-input-id")
      if (!inputId) return

      const input = document.getElementById(inputId)
      if (!input || !input.value) return

      const value = input.value

      try {
        if (navigator.clipboard && navigator.clipboard.writeText) {
          await navigator.clipboard.writeText(value)
        } else {
          const textarea = document.createElement("textarea")
          textarea.value = value
          textarea.style.position = "fixed"
          textarea.style.left = "-9999px"
          textarea.style.top = "0"
          document.body.appendChild(textarea)
          textarea.focus()
          textarea.select()
          document.execCommand("copy")
          document.body.removeChild(textarea)
        }

        this.showCopiedIndicator()
      } catch (error) {
        console.error("Failed to copy invitation link", error)
      }
    }

    this.el.addEventListener("click", this.handleClick)
  },

  destroyed() {
    if (this.handleClick) {
      this.el.removeEventListener("click", this.handleClick)
    }
    if (this._copiedTimeout) {
      clearTimeout(this._copiedTimeout)
    }
  },

  showCopiedIndicator() {
    let badge = this.el.nextElementSibling

    if (!(badge && badge.dataset && badge.dataset.copiedBadge === "true")) {
      badge = document.createElement("span")
      badge.dataset.copiedBadge = "true"
      badge.textContent = "Copied"
      badge.style.marginLeft = "0.5rem"
      badge.style.fontSize = "0.75rem"
      badge.style.fontWeight = "500"
      badge.style.color = "#16a34a"
      badge.style.opacity = "0"
      badge.style.transform = "translateY(2px)"
      badge.style.transition = "opacity 180ms ease-out, transform 180ms ease-out"
      this.el.insertAdjacentElement("afterend", badge)
    } else {
      if (this._copiedTimeout) {
        clearTimeout(this._copiedTimeout)
      }
    }

    requestAnimationFrame(() => {
      badge.style.opacity = "1"
      badge.style.transform = "translateY(0)"
    })

    this._copiedTimeout = window.setTimeout(() => {
      badge.style.opacity = "0"
      badge.style.transform = "translateY(2px)"
    }, 1600)
  },
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: Hooks,
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}
