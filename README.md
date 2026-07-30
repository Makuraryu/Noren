# Noren

Noren is a scrolling terminal multiplexer built around horizontal workspaces.

This repository contains Noren `0.2.0`, the completed **M0–M2
single-Pane persistent Server/Client milestones** from
[`Noren-Agent-开发规范.md`](Noren-Agent-%E5%BC%80%E5%8F%91%E8%A7%84%E8%8C%83.md).
It runs a shell or command in a Server-owned PTY, parses terminal output with
pinned libvterm, and lets a client detach and later recover the latest screen.

## What works in 0.2.0

- Monotonic stable IDs for Sessions, Workspaces, Panes, Clients, Layers and
  asynchronous events.
- Session → ordered Workspaces → horizontal Panes ownership, with explicit
  invariant checking.
- Reducer-driven Pane/Workspace creation, focus, resize, asynchronous close,
  attach/detach and size-owner transfer.
- Pure horizontal layout, clipping and zero-margin minimal reveal.
- Independent Pane borders and a structured bottom status surface.
- A bounded IPC frame parser for the 20-byte `NRN1` header, including
  fragmentation and coalescing.
- Bounded byte queues, validated default configuration and prefix routing.
- A deterministic model demo and comprehensive unit/integration tests.
- macOS/Linux POSIX PTY spawning, cwd/winsize handling, non-blocking I/O,
  process-group signaling and child reaping.
- Vendored libvterm 0.3.3 with UTF-8, color/style, wide-cell, title and
  alternate-screen coverage.
- A raw-mode interactive client with signal self-pipe, idempotent terminal
  restoration, bounded Pane input, prefix routing and a structured ANSI
  renderer.
- A per-user Unix socket with owner-only permissions and peer-UID validation.
- `NRN1` handshake/control JSON, persistent `new -d`, `attach`, full redraw on
  attach and structured Canvas diffs during normal rendering.
- A bounded, non-blocking client output queue; a slow or crashed client cannot
  block PTY draining or destroy the Session.
- End-to-end Neovim detach/reattach coverage.

The current runtime intentionally permits one Server-owned Session with one
Pane. The horizontal multi-Pane runtime is M3. See [the implementation
status](docs/implementation-status.md).

## Build

Noren requires Zig `0.16.0` exactly.

```sh
zig fmt --check src tests build.zig
zig build
zig build test
zig build test-integration
zig build test-e2e
```

If Zig is not on `PATH`, substitute the path to a Zig 0.16.0 executable. Keep
both Zig cache directories inside the repository when working in a restricted
environment:

```sh
ZIG_GLOBAL_CACHE_DIR="$PWD/.zig-cache/global" \
ZIG_LOCAL_CACHE_DIR="$PWD/.zig-cache/local" \
zig build test
```

## Run

```sh
zig build run -- version
zig build run -- info
zig build run -- debug model-demo
zig build run -- new -s work
zig build run -- new -d -s work
zig build run -- attach -t work
zig build run -- new -s build -- /bin/sh -c 'printf "hello\n"'
```

Inside a Session, ordinary bytes go to the Pane. Prefix keys are:

- `Ctrl-b`, then `d`: detach; the command keeps running.
- `Ctrl-b`, then `x`: close the Pane and Session.
- `Ctrl-b`, then `Ctrl-b`: send a literal `Ctrl-b` to the command.

Other reserved prefix commands currently ring the terminal bell until their
M3/M4 runtime feature is implemented.

## Project rules

The implementation specification is normative. In particular, do not add a
Column/Window/split-tree layer, do not use display positions as identity, and
do not let I/O effects mutate the model outside the reducer.

## License

MIT. See [LICENSE](LICENSE).
