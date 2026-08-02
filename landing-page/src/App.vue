<script setup>
import { onMounted, onUnmounted, ref } from 'vue'

const installCommand = 'brew install Makuraryu/tap/noren'
const copied = ref(false)
let copyTimer
let revealObserver

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
})

onUnmounted(() => {
  revealObserver?.disconnect()
  window.clearTimeout(copyTimer)
})
</script>

<template>
  <div class="site-shell">
    <header class="site-header" aria-label="Primary navigation">
      <a class="wordmark" href="#top" aria-label="Noren home">
        <svg aria-hidden="true" viewBox="0 0 32 32">
          <path d="M7 5v22M7 7h18M7 16h18M7 25h18" />
          <path class="mark-accent" d="m19 12 4 4-4 4" />
        </svg>
        <span>Noren</span>
      </a>
      <nav>
        <a href="#why">Why Noren</a>
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
          <div class="eyebrow"><span></span> Terminal workspace, rethought</div>
          <h1>Room for every<br /><em>train of thought.</em></h1>
          <p class="hero-lede">
            Noren is a fast, horizontal terminal multiplexer that keeps your work alive and your context
            within reach.
          </p>
          <div class="hero-actions">
            <a class="button button-primary" href="#install">
              Get Noren
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
          <p class="platform-note">Open source · macOS &amp; Linux</p>
        </div>

        <div class="terminal-scene" data-reveal aria-label="Noren horizontal terminal workspace preview">
          <div class="terminal-window">
            <div class="terminal-titlebar">
              <div class="traffic-lights" aria-hidden="true"><i></i><i></i><i></i></div>
              <span class="terminal-window-title">noren attach</span>
              <span class="terminal-title-meta">...</span>
            </div>
            <div class="terminal-panes">
              <article class="terminal-pane pane-shell">
                <p class="pane-label">~/Noren</p>
                <div class="shell-prompt">
                  <span class="prompt-mark">&gt;</span>
                  <span>/Noren</span>
                  <span class="prompt-help">?</span>
                  <span class="prompt-dollar">$</span>
                  <span class="prompt-command">nvim</span>
                </div>
                <div class="shell-ascii" aria-hidden="true">
                  <span>+----------------+</span>
                  <span>| work           |</span>
                  <span>|                |</span>
                  <span>+----------------+</span>
                </div>
              </article>
              <article class="terminal-pane pane-editor">
                <div class="editor-heading"><span class="editor-line-active">1</span><span>#</span><strong>Noren</strong></div>
                <div class="editor-copy" aria-label="README preview">
                  <p>Noren is a scrolling terminal multiplexer</p>
                  <p>built around horizontal workspaces.</p>
                  <p>&nbsp;</p>
                  <p class="editor-muted">Your work keeps running.</p>
                  <p class="editor-muted">Your context stays within reach.</p>
                  <p>&nbsp;</p>
                  <p><span class="editor-prompt">&gt;</span> attach --session work</p>
                  <p class="editor-cursor"><span></span></p>
                </div>
              </article>
              <article class="terminal-pane pane-workspaces">
                <p class="pane-label">workspaces</p>
                <div class="workspace-list">
                  <div class="workspace-item is-active"><span>[1]</span><strong>work</strong><i>●</i></div>
                  <div class="workspace-item"><span>[2]</span><strong>review</strong><i>○</i></div>
                  <div class="workspace-item"><span>[3]</span><strong>notes</strong><i>○</i></div>
                </div>
              </article>
            </div>
            <div class="terminal-status">
              <span class="status-capsule prefix">Ctrl+b</span>
              <span class="status-capsule">session:work</span>
              <span class="status-spacer"></span>
              <span class="status-capsule">21:55</span>
              <span class="status-capsule status-current">1:2</span>
            </div>
          </div>
          <div class="scene-caption">
            <span>One session</span>
            <span class="caption-line"></span>
            <span>Every pane in reach</span>
          </div>
        </div>
      </section>

      <section id="why" class="why section-wrap">
        <div class="section-heading" data-reveal>
          <p class="section-kicker">Less switching. More doing.</p>
          <h2>Your terminal should follow<br />the shape of your work.</h2>
        </div>
        <div class="feature-grid">
          <article data-reveal>
            <div class="feature-icon icon-horizontal" aria-hidden="true">
              <span></span><span></span><span></span>
            </div>
            <p class="feature-number">01</p>
            <h3>Horizontal by design</h3>
            <p>Move across panes and workspaces in one clear direction. Your mental map stays intact.</p>
          </article>
          <article data-reveal>
            <div class="feature-icon icon-persist" aria-hidden="true">
              <span></span><i></i>
            </div>
            <p class="feature-number">02</p>
            <h3>Work keeps running</h3>
            <p>Detach without disruption. Reconnect later and find every process exactly where you left it.</p>
          </article>
          <article data-reveal>
            <div class="feature-icon icon-native" aria-hidden="true">
              <svg viewBox="0 0 48 48"><path d="M26 4 10 27h13l-1 17 16-25H25l1-15Z" /></svg>
            </div>
            <p class="feature-number">03</p>
            <h3>Native and immediate</h3>
            <p>Built in Zig around real PTYs and libvterm for low overhead and responsive terminal I/O.</p>
          </article>
        </div>
      </section>

      <section id="install" class="install section-wrap">
        <div class="install-panel" data-reveal>
          <div class="install-copy">
            <p class="section-kicker">Start in one command</p>
            <h2>Make some room.</h2>
            <p>Install Noren with Homebrew, then open your first persistent workspace.</p>
          </div>
          <div class="command-area">
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
