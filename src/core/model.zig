const std = @import("std");
const ids = @import("ids.zig");

pub const SessionId = ids.SessionId;
pub const WorkspaceId = ids.WorkspaceId;
pub const PaneId = ids.PaneId;
pub const ClientId = ids.ClientId;

pub const Direction = enum { left, right, up, down };

pub const Size = struct {
    cols: u16,
    rows: u16,
};

pub const PaneState = enum {
    pending,
    running,
    closing_hup,
    closing_term,
    closing_kill,
    draining,
};

pub const Pane = struct {
    id: PaneId,
    workspace_id: WorkspaceId,
    outer_width: u16,
    logical_cols: u16,
    logical_rows: u16,
    state: PaneState,

    pub fn init(
        id: PaneId,
        workspace_id: WorkspaceId,
        outer_width: u16,
        logical_rows: u16,
    ) Pane {
        return .{
            .id = id,
            .workspace_id = workspace_id,
            .outer_width = outer_width,
            .logical_cols = outer_width - 2,
            .logical_rows = logical_rows,
            .state = .pending,
        };
    }
};

pub const Workspace = struct {
    id: WorkspaceId,
    panes: std.ArrayList(PaneId) = .empty,
    focused_pane: usize = 0,
    camera_x: i64 = 0,

    pub fn deinit(self: *Workspace, allocator: std.mem.Allocator) void {
        self.panes.deinit(allocator);
        self.* = undefined;
    }
};

pub const SessionState = enum { running, closing };

pub const Session = struct {
    id: SessionId,
    name: []u8,
    workspaces: std.ArrayList(WorkspaceId) = .empty,
    active_workspace: usize = 0,
    clients: std.ArrayList(ClientId) = .empty,
    size_owner: ?ClientId = null,
    canonical_cols: u16,
    canonical_outer_rows: u16,
    state: SessionState = .running,

    pub fn deinit(self: *Session, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.workspaces.deinit(allocator);
        self.clients.deinit(allocator);
        self.* = undefined;
    }
};

pub const ClientState = struct {
    id: ClientId,
    attached_session: ?SessionId = null,
    size: Size,
    read_only: bool = false,
    ignore_size: bool = false,
    last_activity: u64 = 0,
    needs_full_redraw: bool = true,
};

pub const Limits = struct {
    max_sessions: usize = 64,
    max_workspaces_per_session: usize = 128,
    max_panes_per_session: usize = 256,
    max_clients: usize = 32,
    min_outer_width: u16 = 3,
    max_outer_width: u16 = 4096,
};

pub const ServerModel = struct {
    sessions: std.AutoHashMapUnmanaged(SessionId, Session) = .empty,
    workspaces: std.AutoHashMapUnmanaged(WorkspaceId, Workspace) = .empty,
    panes: std.AutoHashMapUnmanaged(PaneId, Pane) = .empty,
    clients: std.AutoHashMapUnmanaged(ClientId, ClientState) = .empty,
    ids: ids.IdGenerator = .{},
    limits: Limits = .{},
    activity_clock: u64 = 0,

    pub fn init() ServerModel {
        return .{};
    }

    pub fn deinit(self: *ServerModel, allocator: std.mem.Allocator) void {
        var session_it = self.sessions.valueIterator();
        while (session_it.next()) |session| session.deinit(allocator);
        var workspace_it = self.workspaces.valueIterator();
        while (workspace_it.next()) |workspace| workspace.deinit(allocator);

        self.sessions.deinit(allocator);
        self.workspaces.deinit(allocator);
        self.panes.deinit(allocator);
        self.clients.deinit(allocator);
        self.* = undefined;
    }

    pub fn createSession(
        self: *ServerModel,
        allocator: std.mem.Allocator,
        name: []const u8,
        canonical_cols: u16,
        canonical_rows: u16,
    ) !SessionId {
        try validateSessionName(name);
        if (self.sessions.count() >= self.limits.max_sessions) {
            return error.SessionLimitReached;
        }
        if (canonical_cols == 0 or canonical_rows < 3) return error.InvalidSize;

        var existing = self.sessions.valueIterator();
        while (existing.next()) |session| {
            if (std.mem.eql(u8, session.name, name)) return error.DuplicateSessionName;
        }

        const session_id = try self.ids.next(SessionId);
        const workspace_id = try self.ids.next(WorkspaceId);
        const pane_id = try self.ids.next(PaneId);
        const owned_name = try allocator.dupe(u8, name);
        errdefer allocator.free(owned_name);

        var session: Session = .{
            .id = session_id,
            .name = owned_name,
            .canonical_cols = canonical_cols,
            .canonical_outer_rows = canonical_rows,
        };
        errdefer session.deinit(allocator);
        try session.workspaces.append(allocator, workspace_id);

        var workspace: Workspace = .{ .id = workspace_id };
        errdefer workspace.deinit(allocator);
        try workspace.panes.append(allocator, pane_id);

        const initial_width = @min(@as(u16, 80), self.limits.max_outer_width);
        const pane = Pane.init(
            pane_id,
            workspace_id,
            @max(initial_width, self.limits.min_outer_width),
            canonical_rows - 2,
        );

        try self.sessions.put(allocator, session_id, session);
        errdefer _ = self.sessions.remove(session_id);
        try self.workspaces.put(allocator, workspace_id, workspace);
        errdefer _ = self.workspaces.remove(workspace_id);
        try self.panes.put(allocator, pane_id, pane);

        return session_id;
    }

    pub fn addClient(
        self: *ServerModel,
        allocator: std.mem.Allocator,
        size: Size,
        read_only: bool,
    ) !ClientId {
        if (self.clients.count() >= self.limits.max_clients) return error.ClientLimitReached;
        if (size.cols == 0 or size.rows == 0) return error.InvalidSize;
        const id = try self.ids.next(ClientId);
        try self.clients.put(allocator, id, .{
            .id = id,
            .size = size,
            .read_only = read_only,
            .ignore_size = read_only,
        });
        return id;
    }

    pub fn countSessionPanes(self: *const ServerModel, session: *const Session) usize {
        var total: usize = 0;
        for (session.workspaces.items) |workspace_id| {
            const workspace = self.workspaces.get(workspace_id) orelse continue;
            total += workspace.panes.items.len;
        }
        return total;
    }

    pub fn activeWorkspace(self: *ServerModel, session_id: SessionId) ?*Workspace {
        const session = self.sessions.getPtr(session_id) orelse return null;
        if (session.active_workspace >= session.workspaces.items.len) return null;
        return self.workspaces.getPtr(session.workspaces.items[session.active_workspace]);
    }

    pub fn markActivity(self: *ServerModel, client_id: ClientId) void {
        self.activity_clock +%= 1;
        if (self.clients.getPtr(client_id)) |client| {
            client.last_activity = self.activity_clock;
        }
    }
};

pub fn validateSessionName(name: []const u8) !void {
    if (name.len == 0 or name.len > 128) return error.InvalidSessionName;
    if (!std.unicode.utf8ValidateSlice(name)) return error.InvalidSessionName;
    for (name) |byte| {
        if (byte == 0 or byte == '/' or byte < 0x20 or byte == 0x7f) {
            return error.InvalidSessionName;
        }
    }
}

test "session creation establishes one non-empty workspace" {
    const allocator = std.testing.allocator;
    var model = ServerModel.init();
    defer model.deinit(allocator);

    const session_id = try model.createSession(allocator, "work", 120, 40);
    const session = model.sessions.get(session_id).?;
    try std.testing.expectEqual(@as(usize, 1), session.workspaces.items.len);
    const workspace = model.workspaces.get(session.workspaces.items[0]).?;
    try std.testing.expectEqual(@as(usize, 1), workspace.panes.items.len);
}

test "session names are unique validated UTF-8 labels" {
    const allocator = std.testing.allocator;
    var model = ServerModel.init();
    defer model.deinit(allocator);

    _ = try model.createSession(allocator, "工作", 80, 24);
    try std.testing.expectError(
        error.DuplicateSessionName,
        model.createSession(allocator, "工作", 80, 24),
    );
    try std.testing.expectError(
        error.InvalidSessionName,
        model.createSession(allocator, "bad/name", 80, 24),
    );
}
