# Noren

Noren is a scrolling terminal multiplexer built around horizontal workspaces.

This repository contains Noren `0.1.0`, the completed **M0 model and M1
single-Pane PTY/VT milestones** from
[`Noren-Agent-开发规范.md`](Noren-Agent-%E5%BC%80%E5%8F%91%E8%A7%84%E8%8C%83.md).
It is the first working development version: `noren new` runs a shell or command
inside a real PTY, parses its terminal output with pinned libvterm, and renders
it safely in the outer terminal.

## What works in 0.1.0

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

The Unix-socket Server, persistent detach/attach and multi-Pane interactive
runtime are the next milestones and are not advertised as available. See
[the implementation status](docs/implementation-status.md).

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
zig build run -- new -s build -- /bin/sh -c 'printf "hello\n"'
```

Inside `new`, ordinary bytes go to the Pane and `C-b C-b` sends a literal
prefix. `C-b x` closes the local Pane. Commands that require a persistent
Server fail explicitly.

## Project rules

The implementation specification is normative. In particular, do not add a
Column/Window/split-tree layer, do not use display positions as identity, and
do not let I/O effects mutate the model outside the reducer.

## License

MIT. See [LICENSE](LICENSE).
