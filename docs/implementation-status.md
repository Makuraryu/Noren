# Implementation status

Version 0.2.0 completes the specification's M0 through M2 milestones.

| Area | Status | Notes |
| --- | --- | --- |
| Stable IDs and ownership model | Complete | IDs never reused in-process |
| Action / Reducer / Effect | Complete | Includes async close and size owner |
| Debug invariant checks | Complete | Run after every reducer Action |
| Pure layout and reveal | Complete | Absolute widths, zero reveal margin |
| Structured Cell/Canvas/borders | Complete | No Pane ANSI passthrough |
| IPC framing and bounds | Complete | Fragmentation/coalescing tested |
| Prefix router and config defaults | Complete | Validated, bounded values |
| POSIX PTY and libvterm | Complete | Real PTY, libvterm 0.3.3, raw-mode client |
| Unix socket Server/Client | Complete M2 | Persistent one-Pane Session |
| Full/diff rendering | Complete M2 | Full attach snapshot, Canvas cell diffs |
| Client backpressure | Complete M2 | 4 MiB non-blocking bounded queue |
| Interactive Pane strip | Planned M3 | Model/layout behavior is ready |
| Workspaces and multi-client UI | Planned M4–M6 | Model behavior is ready |

The M2 runtime supports one persistent Session and one Pane. `new -d`, `attach`
and `Ctrl-b d` are available. Multiple interactive Panes and Workspaces remain
unavailable until M3/M4. This staging follows section 25 of the normative
specification.
