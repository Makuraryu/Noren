//! Noren's reusable core.
//!
//! Platform effects deliberately live outside the model. This root exports the
//! pure M0 building blocks used by the executable and tests.

pub const core = struct {
    pub const ids = @import("core/ids.zig");
    pub const model = @import("core/model.zig");
    pub const action = @import("core/action.zig");
    pub const effect = @import("core/effect.zig");
    pub const invariant = @import("core/invariant.zig");
    pub const reducer = @import("core/reducer.zig");
    pub const bounded_queue = @import("core/bounded_queue.zig");
};

pub const config = @import("config/config.zig");
pub const layout = struct {
    pub const placement = @import("layout/placement.zig");
    pub const workspace = @import("layout/workspace.zig");
    pub const reveal = @import("layout/reveal.zig");
};
pub const protocol = struct {
    pub const frame = @import("protocol/frame.zig");
};
pub const terminal = struct {
    pub const cell = @import("terminal/cell.zig");
    pub const backend = @import("terminal/backend.zig");
};
pub const render = struct {
    pub const canvas = @import("render/canvas.zig");
    pub const compositor = @import("render/compositor.zig");
    pub const ansi = @import("render/ansi.zig");
};
pub const input = struct {
    pub const prefix = @import("input/prefix.zig");
};
pub const os = struct {
    pub const pty = @import("os/pty.zig");
};
pub const client = struct {
    pub const raw_mode = @import("client/raw_mode.zig");
    pub const interactive = @import("client/interactive.zig");
};

test {
    _ = core.ids;
    _ = core.model;
    _ = core.action;
    _ = core.effect;
    _ = core.invariant;
    _ = core.reducer;
    _ = core.bounded_queue;
    _ = config;
    _ = layout.placement;
    _ = layout.workspace;
    _ = layout.reveal;
    _ = protocol.frame;
    _ = terminal.cell;
    _ = terminal.backend;
    _ = render.canvas;
    _ = render.compositor;
    _ = render.ansi;
    _ = input.prefix;
    _ = os.pty;
    _ = client.raw_mode;
    _ = client.interactive;
}
