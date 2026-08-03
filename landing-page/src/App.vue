<script setup>
import { onMounted, onUnmounted, ref } from 'vue'

const installCommand = 'brew install Makuraryu/tap/noren'
const copied = ref(false)
const pixelBlastCanvas = ref(null)
const demoVideo = ref(null)
const demoPlaying = ref(false)
let copyTimer
let revealObserver
let demoVisibilityObserver
let motionPreference
let pixelContext
let pixelFrame
let pixelTracking = false
let demoVisible = false
let demoUserPaused = false
let demoManualPlay = false
let canvasWidth = 0
let canvasHeight = 0
const pixelPointer = {
  x: 0,
  y: 0,
  intensity: 0,
  targetIntensity: 0,
}

function pixelVariation(column, row) {
  const value = Math.sin(column * 12.9898 + row * 78.233) * 43758.5453
  return value - Math.floor(value)
}

function drawPixelBlast() {
  if (!pixelContext || !canvasWidth || !canvasHeight) return

  pixelContext.clearRect(0, 0, canvasWidth, canvasHeight)
  const spacing = canvasWidth < 720 ? 18 : 22
  const radius = Math.min(320, Math.max(210, Math.min(canvasWidth, canvasHeight) * 0.4))

  for (let row = 0, y = spacing / 2; y < canvasHeight; row += 1, y += spacing) {
    for (let column = 0, x = spacing / 2; x < canvasWidth; column += 1, x += spacing) {
      const variation = pixelVariation(column, row)
      const distance = Math.hypot(x - pixelPointer.x, y - pixelPointer.y)
      const proximity = Math.max(0, 1 - distance / radius)
      const glow = proximity * proximity * pixelPointer.intensity
      const alpha = 0.032 + glow * (0.48 + variation * 0.36)
      const size = 1.7 + variation * 1.2 + glow * (3.4 + variation * 1.5)

      pixelContext.fillStyle = `rgba(202, 207, 212, ${alpha.toFixed(3)})`
      pixelContext.fillRect(Math.round(x - size / 2), Math.round(y - size / 2), size, size)
    }
  }
}

function animatePixelBlast() {
  pixelPointer.intensity += (pixelPointer.targetIntensity - pixelPointer.intensity) * 0.18
  if (Math.abs(pixelPointer.targetIntensity - pixelPointer.intensity) < 0.01) {
    pixelPointer.intensity = pixelPointer.targetIntensity
  }

  drawPixelBlast()
  pixelFrame = undefined
  if (pixelPointer.intensity !== pixelPointer.targetIntensity) schedulePixelBlast()
}

function schedulePixelBlast() {
  if (!pixelFrame) pixelFrame = window.requestAnimationFrame(animatePixelBlast)
}

function resizePixelBlast() {
  const canvas = pixelBlastCanvas.value
  if (!canvas || !pixelContext) return

  const pixelRatio = Math.min(window.devicePixelRatio || 1, 2)
  canvasWidth = window.innerWidth
  canvasHeight = window.innerHeight
  canvas.width = Math.round(canvasWidth * pixelRatio)
  canvas.height = Math.round(canvasHeight * pixelRatio)
  pixelContext.setTransform(pixelRatio, 0, 0, pixelRatio, 0, 0)
  if (!pixelPointer.x && !pixelPointer.y) {
    pixelPointer.x = canvasWidth / 2
    pixelPointer.y = canvasHeight / 2
  }
  drawPixelBlast()
}

function handlePointerMove(event) {
  if (event.pointerType && event.pointerType !== 'mouse') return

  pixelPointer.x = event.clientX
  pixelPointer.y = event.clientY
  pixelPointer.targetIntensity = 1
  schedulePixelBlast()
}

function resetPixelBlastPointer() {
  pixelPointer.targetIntensity = 0
  schedulePixelBlast()
}

function syncDemoPlayback() {
  const video = demoVideo.value
  if (!video) return

  const reduceMotion = motionPreference?.matches ?? false
  const shouldPlay = demoVisible && (!reduceMotion || demoManualPlay) && !demoUserPaused

  if (shouldPlay) {
    video.play().catch(() => {
      demoPlaying.value = false
    })
  } else {
    video.pause()
  }
}

function toggleDemoPlayback() {
  const video = demoVideo.value
  if (!video) return

  if (video.paused) {
    demoUserPaused = false
    demoManualPlay = true
    video.play().catch(() => {
      demoPlaying.value = false
    })
  } else {
    demoUserPaused = true
    demoManualPlay = false
    video.pause()
  }
}

function handleMotionPreferenceChange() {
  demoManualPlay = false
  syncDemoPlayback()
}

function handleDemoPlay() {
  demoPlaying.value = true
}

function handleDemoPause() {
  demoPlaying.value = false
}

async function copyInstallCommand() {
  try {
    await navigator.clipboard.writeText(installCommand)
    copied.value = true
    window.clearTimeout(copyTimer)
    copyTimer = window.setTimeout(() => (copied.value = false), 1800)
  } catch {
    copied.value = false
  }
}

onMounted(() => {
  motionPreference = window.matchMedia('(prefers-reduced-motion: reduce)')
  motionPreference.addEventListener('change', handleMotionPreferenceChange)

  const revealItems = document.querySelectorAll('[data-reveal]')
  revealObserver = new IntersectionObserver(
    (entries) => {
      entries.forEach((entry) => {
        if (entry.isIntersecting) {
          entry.target.classList.add('is-visible')
          revealObserver.unobserve(entry.target)
        }
      })
    },
    { threshold: 0.18 },
  )

  revealItems.forEach((item) => revealObserver.observe(item))

  demoVisibilityObserver = new IntersectionObserver(
    ([entry]) => {
      demoVisible = entry.isIntersecting
      syncDemoPlayback()
    },
    { threshold: 0.25 },
  )
  if (demoVideo.value) demoVisibilityObserver.observe(demoVideo.value)

  pixelContext = pixelBlastCanvas.value?.getContext('2d', { alpha: true })
  resizePixelBlast()
  window.addEventListener('resize', resizePixelBlast, { passive: true })

  if (!motionPreference.matches && pixelContext) {
    pixelTracking = true
    window.addEventListener('pointermove', handlePointerMove, { passive: true })
    window.addEventListener('blur', resetPixelBlastPointer)
    document.documentElement.addEventListener('mouseleave', resetPixelBlastPointer)
  }
})

onUnmounted(() => {
  revealObserver?.disconnect()
  demoVisibilityObserver?.disconnect()
  motionPreference?.removeEventListener('change', handleMotionPreferenceChange)
  window.clearTimeout(copyTimer)
  window.removeEventListener('resize', resizePixelBlast)
  if (pixelTracking) {
    window.removeEventListener('pointermove', handlePointerMove)
    window.removeEventListener('blur', resetPixelBlastPointer)
    document.documentElement.removeEventListener('mouseleave', resetPixelBlastPointer)
  }
  if (pixelFrame) window.cancelAnimationFrame(pixelFrame)
  pixelContext = undefined
})
</script>

<template>
  <div class="site-shell">
    <canvas ref="pixelBlastCanvas" class="pixel-blast" aria-hidden="true"></canvas>
    <header class="site-header" aria-label="Primary navigation">
      <a class="wordmark" href="#top" aria-label="Noren home">
        <svg aria-hidden="true" viewBox="0 0 32 32">
          <path d="M7 5v22M7 7h18M7 16h18M7 25h18" />
          <path class="mark-accent" d="m19 12 4 4-4 4" />
        </svg>
        <span>Noren</span>
      </a>
      <nav>
        <a href="#example">Example</a>
        <a href="#why">Scrollable tiling</a>
        <a href="#install">Install</a>
        <a
          class="nav-github"
          href="https://github.com/Makuraryu/Noren"
          target="_blank"
          rel="noreferrer"
        >
          GitHub
          <svg aria-hidden="true" viewBox="0 0 16 16"><path d="M5 11 11 5M6 5h5v5" /></svg>
        </a>
      </nav>
    </header>

    <main id="top">
      <section class="hero section-wrap">
        <div class="hero-copy" data-reveal>
          <div class="eyebrow"><span></span> Scrollable tiling for terminal work</div>
          <h1>Keep moving.<br /><em>Keep context.</em></h1>
          <p class="hero-lede">
            Noren is a terminal multiplexer built around scrollable tiling. Move through horizontal
            workspaces without losing the process, pane, or thought you were in.
          </p>
          <div class="hero-actions">
            <a class="button button-primary" href="#install">
              Install Noren
              <svg aria-hidden="true" viewBox="0 0 20 20"><path d="m5 8 5 5 5-5" /></svg>
            </a>
            <a
              class="button button-quiet"
              href="https://github.com/Makuraryu/Noren"
              target="_blank"
              rel="noreferrer"
            >
              View source
            </a>
          </div>
          <div id="install" class="hero-install">
            <p class="section-kicker">Start in one command</p>
            <button
              class="command"
              type="button"
              :class="{ 'is-copied': copied }"
              :aria-label="copied ? 'Install command copied' : 'Copy install command'"
              @click="copyInstallCommand"
            >
              <code><span>$</span> {{ installCommand }}</code>
              <span class="copy-state" aria-live="polite">
                <svg v-if="!copied" aria-hidden="true" viewBox="0 0 20 20"><rect x="7" y="7" width="9" height="9" rx="2" /><path d="M13 7V5a2 2 0 0 0-2-2H5a2 2 0 0 0-2 2v6a2 2 0 0 0 2 2h2" /></svg>
                <svg v-else aria-hidden="true" viewBox="0 0 20 20"><path d="m4 10 4 4 8-8" /></svg>
                {{ copied ? 'Copied' : 'Copy' }}
              </span>
            </button>
            <a
              href="https://github.com/Makuraryu/Noren#linux-vps-installer"
              target="_blank"
              rel="noreferrer"
            >
              Linux installer and build instructions
              <svg aria-hidden="true" viewBox="0 0 16 16"><path d="M5 11 11 5M6 5h5v5" /></svg>
            </a>
          </div>
          <p class="platform-note">Open source · macOS &amp; Linux</p>
        </div>

      </section>

      <section id="example" class="example section-wrap">
        <div class="example-heading" data-reveal>
          <p class="section-kicker">A real workspace</p>
          <h2>Noren<br /><em>in the terminal.</em></h2>
          <p>
            Open panes without shrinking what is already there. Pan across the strip, switch
            Workspaces, detach, and return with every process intact.
          </p>
        </div>
        <figure class="example-figure" data-reveal>
          <div class="example-image-frame">
            <video
              ref="demoVideo"
              src="/noren-demo.mp4"
              poster="/noren.png"
              muted
              loop
              playsinline
              preload="metadata"
              aria-label="Noren demo showing panes opening across a horizontal workspace, followed by detach and reattach."
              @play="handleDemoPlay"
              @pause="handleDemoPause"
            >
              Your browser does not support embedded video.
            </video>
            <button
              class="demo-control"
              type="button"
              :aria-label="demoPlaying ? 'Pause Noren demo' : 'Play Noren demo'"
              @click="toggleDemoPlayback"
            >
              <svg v-if="demoPlaying" aria-hidden="true" viewBox="0 0 16 16">
                <path d="M5 3v10M11 3v10" />
              </svg>
              <svg v-else aria-hidden="true" viewBox="0 0 16 16">
                <path d="m5 3 8 5-8 5Z" />
              </svg>
              {{ demoPlaying ? 'Pause demo' : 'Play demo' }}
            </button>
          </div>
          <figcaption>
            <span>32-second walkthrough</span>
            <span>create panes · move horizontally · detach · reattach</span>
          </figcaption>
        </figure>
      </section>

      <section id="why" class="why section-wrap">
        <div class="section-heading" data-reveal>
          <p class="section-kicker">Scrollable tiling</p>
          <h2>Pan across the work,<br />not away from it.</h2>
        </div>
        <div class="feature-grid">
          <article data-reveal>
            <div class="feature-icon icon-horizontal" aria-hidden="true">
              <span></span><span></span><span></span>
            </div>
            <p class="feature-number">01</p>
            <h3>Scroll the workspace</h3>
            <p>Move across panes and workspaces in one clear direction. Your mental map stays intact.</p>
          </article>
          <article data-reveal>
            <div class="feature-icon icon-persist" aria-hidden="true">
              <span></span><i></i>
            </div>
            <p class="feature-number">02</p>
            <h3>Keep sessions alive</h3>
            <p>Detach without disruption. Reconnect later and find every process exactly where you left it.</p>
          </article>
          <article data-reveal>
            <div class="feature-icon icon-native" aria-hidden="true">
              <svg viewBox="0 0 48 48"><path d="M26 4 10 27h13l-1 17 16-25H25l1-15Z" /></svg>
            </div>
            <p class="feature-number">03</p>
            <h3>Stay close to the terminal</h3>
            <p>Built in Zig around real PTYs and libvterm for low overhead and responsive terminal I/O.</p>
          </article>
        </div>
      </section>

    </main>

    <footer class="section-wrap">
      <div class="footer-mark">
        <svg aria-hidden="true" viewBox="0 0 32 32">
          <path d="M7 5v22M7 7h18M7 16h18M7 25h18" />
          <path class="mark-accent" d="m19 12 4 4-4 4" />
        </svg>
        <span>Noren</span>
      </div>
      <p>Quiet tools for focused work.</p>
      <div class="footer-links">
        <a href="https://github.com/Makuraryu/Noren" target="_blank" rel="noreferrer">GitHub</a>
        <a href="https://github.com/Makuraryu/Noren/blob/main/LICENSE" target="_blank" rel="noreferrer">MIT License</a>
      </div>
    </footer>
  </div>
</template>
