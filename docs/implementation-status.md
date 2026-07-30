# Implementation status

Version 0.1.0 completes the specification's M0 and M1 milestones.

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
| Unix socket Server/Client | Planned M2 | Frame layer is ready |
| Interactive Pane strip | Planned M3 | Model/layout behavior is ready |
| Workspaces and multi-client UI | Planned M4–M6 | Model behavior is ready |

The M1 runtime supports one foreground Pane. It does not yet persist when the
client exits; `-d`, `attach`, multiple interactive Panes and Workspaces remain
unavailable and fail explicitly. This staging follows section 25 of the
normative specification.
