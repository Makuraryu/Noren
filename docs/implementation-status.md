# Implementation status

Version 0.4.3 completes the specification's M0 through M4 milestones.
The current development tree additionally includes cursor synchronization,
Pane selection by mouse, application-aware mouse forwarding and runtime
disconnect hardening.

| Area | Status | Notes |
| --- | --- | --- |
| Stable IDs and ownership model | Complete | IDs never reused in-process |
| Action / Reducer / Effect | Complete | Includes async close and size owner |
| Debug invariant checks | Complete | Run after every reducer Action |
| Pure layout and reveal | Complete | Absolute widths, zero reveal margin |
| Structured Cell/Canvas/borders | Complete | No Pane ANSI passthrough |
| IPC framing and bounds | Complete | Fragmentation/coalescing tested |
| Prefix router and config defaults | Complete | Visual menu and continuous adjustment |
| POSIX PTY and libvterm | Complete | Real PTY, libvterm 0.3.3, raw-mode client |
| Unix socket Server/Client | Complete M4 | Persistent multi-Pane Session |
| Full/diff rendering | Complete M2 | Full attach snapshot, Canvas cell diffs |
| Client backpressure | Complete M2 | 4 MiB non-blocking bounded queue |
| Interactive Pane strip | Complete M3 | Independent PTY, width, focus and camera |
| Interactive Workspaces | Complete M4 | Independent focus/camera and auto removal |
| Nord capsule status | Complete | Normal info and Nerd Font prefix-key menus |
| Session rename | Complete | Interactive rename and new attach target |
| Cursor visibility | Complete | Follows libvterm cursor-visible property |
| Mouse clicks | Complete | Pane focus plus opt-in child-app forwarding |
| Long-runtime hardening | Complete | Reclaiming allocator, SIGPIPE-safe writes, reconnect E2E |
| Multi-client and Session switching | Planned M5 | Current Server owns one Session/Client |

The M4 runtime supports one persistent Session with multiple interactive Panes
and Workspaces. `new -d`, `attach`, detach/reattach, horizontal camera
navigation, independent Pane resize, Workspace switching, and asynchronous
close escalation are available. `[`/`]` resize Pane width while `h`/`l`
scroll the horizontal camera one cell; all four remain in prefix mode for
continuous adjustment. Multi-Client size ownership and application
Session switching remain staged for M5.
