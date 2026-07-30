# Architecture

Noren is split around ownership and side effects.

```text
CLI
 │
 ▼
Single-threaded Server reactor
 │ ActionEnvelope
 ▼
Reducer ───────────────► bounded Effect queue ─► OS/PTY/IPC executors
 │
 ▼
ServerModel
 │ immutable snapshots
 ├────────► layout ─► Placement
 └────────► terminal CellGrid ─► compositor ─► Client Canvas
```

## Ownership

`ServerModel` owns Sessions, Workspaces, Panes and Clients in maps keyed by
stable monotonic IDs. A Session stores only ordered Workspace IDs; a Workspace
stores only ordered Pane IDs. The model never keeps a long-lived pointer into a
resizable collection.

The reducer is the only shared-state writer. It performs a logical transition
and appends an Effect such as `spawn_pane`, `resize_pty` or
`signal_process_group`. An executor must report success or failure as a new
Action. This keeps failed syscalls from being represented as successful state.

## Dependency boundaries

- `core`: IDs, owned model, Actions, Effects and invariant checks.
- `layout`: pure geometry snapshots; no fd, IPC or ANSI knowledge.
- `terminal`: structured grapheme cells and styles.
- `render`: Cell/Placement composition; no process or model mutation.
- `protocol`: bounded binary framing; no business decisions.
- `input`: byte/event routing into structured commands.
- `config`: validated policy values and hard resource limits.

The M4 Server owns every Pane PTY and terminal backend. The client owns only
outer-TTY raw mode, prefix routing, and IPC. It synchronizes the ephemeral
prefix-menu visibility to the Server compositor; this presentation state is
reset on attach or disconnect and is not part of the durable model. A
disconnect therefore cannot terminate or invalidate a Pane.

## Lifecycles

Pane creation is two-phase: the reducer inserts a `pending` Pane and emits
`spawn_pane`; `pane_spawned` makes it `running`, while `pane_spawn_failed`
removes it and repairs focus.

Pane close is asynchronous:

```text
running → closing_hup → closing_term → closing_kill → draining → removed
```

The final Pane removes its Workspace; the final Workspace ends its Session.
Client detach only severs the attachment and never removes Pane state.
Attach/detach targets a Session as a group: all Workspaces, Pane PTYs and
terminal surfaces remain Server-owned while no Client is attached.

## M4 byte path

```text
all Pane children → PTYs → libvterm surfaces → horizontal placement/compositor
                                                        ↓ Canvas full/diff
                                            bounded NRN1 output queue ↓
outer TTY ← ANSI bytes ← Unix socket ← Server
outer TTY → prefix router → structured Action or bounded Pane input → PTY
```

The outer terminal never receives child ANSI directly. Server socket writes
are non-blocking and capped, so slow clients cannot stop PTY draining. A signal
self-pipe wakes the client for resize and termination; terminal restoration is
one idempotent cleanup path.

Every Pane remains registered with the multi-fd reactor whether visible,
clipped, or in a background Workspace. Close deadlines share that reactor and
advance the reducer-owned `HUP → TERM → KILL → draining` state machine without
blocking sleeps.
