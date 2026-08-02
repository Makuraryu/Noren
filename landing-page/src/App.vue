<script setup>
import { onMounted, onUnmounted, ref } from 'vue'

const installCommand = 'brew install Makuraryu/tap/noren'
const copied = ref(false)
let copyTimer
let revealObserver
let pointerFrame
let pointerTracking = false
let pointerTargetX = 0
let pointerTargetY = 0

function applyPixelBlastPointer(x = 0, y = 0) {
  const root = document.documentElement
  root.style.setProperty('--pixel-blast-x', `${(x * 18).toFixed(2)}px`)
  root.style.setProperty('--pixel-blast-y', `${(y * 14).toFixed(2)}px`)
  root.style.setProperty('--pixel-blast-x-reverse', `${(x * -12).toFixed(2)}px`)
  root.style.setProperty('--pixel-blast-y-reverse', `${(y * -9).toFixed(2)}px`)
}

function handlePointerMove(event) {
  if (event.pointerType && event.pointerType !== 'mouse') return

  pointerTargetX = (event.clientX / window.innerWidth - 0.5) * 2
  pointerTargetY = (event.clientY / window.innerHeight - 0.5) * 2
  if (pointerFrame) return

  pointerFrame = window.requestAnimationFrame(() => {
    applyPixelBlastPointer(pointerTargetX, pointerTargetY)
    pointerFrame = undefined
  })
}

function resetPixelBlastPointer() {
  if (pointerFrame) {
    window.cancelAnimationFrame(pointerFrame)
    pointerFrame = undefined
  }
  applyPixelBlastPointer()
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

  if (!window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
    pointerTracking = true
    window.addEventListener('pointermove', handlePointerMove, { passive: true })
    window.addEventListener('blur', resetPixelBlastPointer)
  }
})

onUnmounted(() => {
  revealObserver?.disconnect()
  window.clearTimeout(copyTimer)
  if (pointerTracking) {
    window.removeEventListener('pointermove', handlePointerMove)
    window.removeEventListener('blur', resetPixelBlastPointer)
    resetPixelBlastPointer()
  }
})
</script>

<template>
  <div class="site-shell">
    <div class="pixel-blast" aria-hidden="true"></div>
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
            One attach brings the whole session into view: a shell, an editor, and the workspaces you
            move through every day.
          </p>
        </div>
        <figure class="example-figure" data-reveal>
          <div class="example-image-frame">
            <img
              src="/noren.png"
              alt="Noren showing a shell, Neovim editor, workspace list, and status bar."
              loading="lazy"
            />
          </div>
          <figcaption>
            <span>noren new</span>
            <span>persistent server · horizontal panes · workspace navigation</span>
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
