# Noren vendoring record

- Upstream: `https://github.com/neovim/libvterm`
- Version: `v0.3.3`
- Archive:
  `https://github.com/neovim/libvterm/archive/refs/tags/v0.3.3.tar.gz`
- Archive SHA-256:
  `0babe3ab42c354925dadede90d352f054aa9c4ae6842ea803a20c9741e172e56`
- Retrieved: 2026-07-30

The release tag does not include generated encoding tables. Noren generated
`src/encoding/DECdrawing.inc` and `src/encoding/uk.inc` with the upstream
`tbl2inc_c.pl`, and retains the upstream-generated `src/fullwidth.inc`.

The upstream license is preserved in `LICENSE`. Noren compiles the pinned C
sources directly through `build.zig`; no system libvterm is used.
