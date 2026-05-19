//! Note-Taking Server Example
//!
//! An MCP server that manages in-memory text notes.
//! Demonstrates:
//! - Stateful server (server context via user_data pointer)
//! - Dynamic resource list (one resource per note)
//! - tools/list notifications when notes change
//! - String and enum schema fields
//! - List-change notifications

const std = @import("std");
const mcp = @import("mcp");

const NoteStore = struct {
    allocator: std.mem.Allocator,
    notes: std.StringHashMap([]const u8),

    fn init(allocator: std.mem.Allocator) NoteStore {
        return .{ .allocator = allocator, .notes = .init(allocator) };
    }

    fn deinit(self: *NoteStore) void {
        var it = self.notes.iterator();
        while (it.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            self.allocator.free(e.value_ptr.*);
        }
        self.notes.deinit();
    }

    fn add(self: *NoteStore, title: []const u8, body: []const u8) !void {
        const k = try self.allocator.dupe(u8, title);
        const v = try self.allocator.dupe(u8, body);
        try self.notes.put(k, v);
    }

    fn get(self: *NoteStore, title: []const u8) ?[]const u8 {
        return self.notes.get(title);
    }

    fn delete(self: *NoteStore, title: []const u8) bool {
        if (self.notes.fetchRemove(title)) |kv| {
            self.allocator.free(kv.key);
            self.allocator.free(kv.value);
            return true;
        }
        return false;
    }
};

// Handler context shared across all tool callbacks
const Ctx = struct {
    store: NoteStore,
    server: *mcp.Server,
    io: std.Io,
    alloc: std.mem.Allocator,
};

pub fn main(init: std.process.Init) void {
    run(init.io, init.gpa) catch |err| mcp.reportError(err);
}

fn run(io: std.Io, allocator: std.mem.Allocator) !void {
    var sa_arena = std.heap.ArenaAllocator.init(allocator);
    defer sa_arena.deinit();
    const sa = sa_arena.allocator();

    const create_schema = try buildCreateSchema(sa);
    const read_schema = try buildReadSchema(sa);
    const delete_schema = try buildReadSchema(sa); // same shape: just a title field

    var server: mcp.Server = .init(allocator, .{
        .name = "notes-server",
        .version = "1.0.0",
        .title = "Note-Taking Server",
        .description = "Create, read, and delete in-memory text notes",
        .instructions = "Use create_note, read_note, delete_note, and list_notes.",
    });
    defer server.deinit();

    var ctx: Ctx = .{
        .store = NoteStore.init(allocator),
        .server = &server,
        .io = io,
        .alloc = allocator,
    };
    defer ctx.store.deinit();

    // Seed some demo notes
    try ctx.store.add("Welcome", "Welcome to the Notes MCP server!\nBuilt with mcp.zig v0.0.5.");
    try ctx.store.add("README", "This server stores notes in memory.\nAll notes are lost on restart.");

    try server.addTool(.{
        .name = "create_note",
        .description = "Create or overwrite a note with the given title and body",
        .title = "Create Note",
        .inputSchema = create_schema,
        .annotations = .{ .destructiveHint = true },
        .user_data = &ctx,
        .handler = createNoteHandler,
    });
    try server.addTool(.{
        .name = "read_note",
        .description = "Read the body of a note by title",
        .title = "Read Note",
        .inputSchema = read_schema,
        .annotations = .{ .readOnlyHint = true, .idempotentHint = true },
        .user_data = &ctx,
        .handler = readNoteHandler,
    });
    try server.addTool(.{
        .name = "delete_note",
        .description = "Delete a note by title",
        .title = "Delete Note",
        .inputSchema = delete_schema,
        .annotations = .{ .destructiveHint = true },
        .user_data = &ctx,
        .handler = deleteNoteHandler,
    });
    try server.addTool(.{
        .name = "list_notes",
        .description = "List all note titles",
        .title = "List Notes",
        .annotations = .{ .readOnlyHint = true, .idempotentHint = true },
        .user_data = &ctx,
        .handler = listNotesHandler,
    });

    // Static resource: notes index
    try server.addResource(.{
        .uri = "notes://index",
        .name = "Notes Index",
        .description = "List of all note titles",
        .mimeType = "text/plain",
        .user_data = &ctx,
        .handler = notesIndexHandler,
    });
    // Resource template for individual notes
    try server.addResourceTemplate(.{
        .uriTemplate = "notes://{title}",
        .name = "note",
        .title = "Note",
        .description = "Access a note by its title via notes://<title>",
        .mimeType = "text/plain",
    });

    server.enableLogging();
    try server.run(io, allocator, .stdio);
}

fn buildCreateSchema(allocator: std.mem.Allocator) !mcp.types.InputSchema {
    var b = mcp.schema.InputSchemaBuilder.init(allocator);
    defer b.deinit(allocator);
    _ = b.setSchemaDialect("https://json-schema.org/draft/2020-12/schema");
    _ = try b.addString(allocator, "title", "Unique note title", true);
    _ = try b.addString(allocator, "body", "Note content (plain text)", true);
    return b.toInputSchema(allocator);
}

fn buildReadSchema(allocator: std.mem.Allocator) !mcp.types.InputSchema {
    var b = mcp.schema.InputSchemaBuilder.init(allocator);
    defer b.deinit(allocator);
    _ = b.setSchemaDialect("https://json-schema.org/draft/2020-12/schema");
    _ = try b.addString(allocator, "title", "Note title", true);
    return b.toInputSchema(allocator);
}

fn createNoteHandler(user_data: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const ctx: *Ctx = @ptrCast(@alignCast(user_data.?));
    const title = mcp.tools.getString(args, "title") orelse
        return mcp.tools.errorResult(allocator, "Missing argument: title") catch return mcp.tools.ToolError.OutOfMemory;
    const body = mcp.tools.getString(args, "body") orelse
        return mcp.tools.errorResult(allocator, "Missing argument: body") catch return mcp.tools.ToolError.OutOfMemory;

    ctx.store.add(title, body) catch return mcp.tools.ToolError.OutOfMemory;

    // Notify clients that resources changed (new note = new resource)
    ctx.server.notifyResourcesChanged(io, allocator) catch {};

    const msg = std.fmt.allocPrint(allocator, "Note '{s}' created ({d} bytes)", .{ title, body.len }) catch
        return mcp.tools.ToolError.OutOfMemory;
    return mcp.tools.textResult(allocator, msg) catch return mcp.tools.ToolError.OutOfMemory;
}

fn readNoteHandler(user_data: ?*anyopaque, _: std.Io, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const ctx: *Ctx = @ptrCast(@alignCast(user_data.?));
    const title = mcp.tools.getString(args, "title") orelse
        return mcp.tools.errorResult(allocator, "Missing argument: title") catch return mcp.tools.ToolError.OutOfMemory;
    const body = ctx.store.get(title) orelse {
        const msg = std.fmt.allocPrint(allocator, "Note not found: '{s}'", .{title}) catch
            return mcp.tools.ToolError.OutOfMemory;
        return mcp.tools.errorResult(allocator, msg) catch return mcp.tools.ToolError.OutOfMemory;
    };
    return mcp.tools.textResult(allocator, body) catch return mcp.tools.ToolError.OutOfMemory;
}

fn deleteNoteHandler(user_data: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const ctx: *Ctx = @ptrCast(@alignCast(user_data.?));
    const title = mcp.tools.getString(args, "title") orelse
        return mcp.tools.errorResult(allocator, "Missing argument: title") catch return mcp.tools.ToolError.OutOfMemory;
    if (!ctx.store.delete(title)) {
        const msg = std.fmt.allocPrint(allocator, "Note not found: '{s}'", .{title}) catch
            return mcp.tools.ToolError.OutOfMemory;
        return mcp.tools.errorResult(allocator, msg) catch return mcp.tools.ToolError.OutOfMemory;
    }
    ctx.server.notifyResourcesChanged(io, allocator) catch {};
    const msg = std.fmt.allocPrint(allocator, "Note '{s}' deleted", .{title}) catch
        return mcp.tools.ToolError.OutOfMemory;
    return mcp.tools.textResult(allocator, msg) catch return mcp.tools.ToolError.OutOfMemory;
}

fn listNotesHandler(user_data: ?*anyopaque, _: std.Io, allocator: std.mem.Allocator, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const ctx: *Ctx = @ptrCast(@alignCast(user_data.?));
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var it = ctx.store.notes.iterator();
    while (it.next()) |e| {
        if (std.fmt.allocPrint(allocator, "- {s}\n", .{e.key_ptr.*})) |str| {
            buf.appendSlice(allocator, str) catch {};
            allocator.free(str);
        } else |_| {}
    }
    const list = buf.toOwnedSlice(allocator) catch return mcp.tools.ToolError.OutOfMemory;
    return mcp.tools.textResult(allocator, list) catch return mcp.tools.ToolError.OutOfMemory;
}

fn notesIndexHandler(user_data: ?*anyopaque, _: std.Io, allocator: std.mem.Allocator, uri: []const u8) mcp.resources.ResourceError!mcp.resources.ResourceContent {
    const ctx: *Ctx = @ptrCast(@alignCast(user_data.?));
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    if (std.fmt.allocPrint(allocator, "Notes Index ({d} notes)\n\n", .{ctx.store.notes.count()})) |str| {
        buf.appendSlice(allocator, str) catch {};
        allocator.free(str);
    } else |_| {}
    var it = ctx.store.notes.iterator();
    while (it.next()) |e| {
        if (std.fmt.allocPrint(allocator, "- {s}\n", .{e.key_ptr.*})) |str| {
            buf.appendSlice(allocator, str) catch {};
            allocator.free(str);
        } else |_| {}
    }
    const text = buf.toOwnedSlice(allocator) catch return mcp.resources.ResourceError.OutOfMemory;
    return .{ .uri = uri, .mimeType = "text/plain", .text = text };
}
