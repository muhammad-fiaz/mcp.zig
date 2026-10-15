//! Full Client/Server Round-Trip Example
//!
//! The other client examples only cover discovery and list operations. This
//! one wires a real `Client` to a real `Server` over an in-memory transport and
//! exercises every client-side operation end to end, including `tools/call`,
//! `resources/read` and `prompts/get`, asserting on each response so that
//! `run-all-examples` fails loudly if client or server support regresses.
//!
//! Run: zig build run-full-client

const std = @import("std");
const mcp = @import("mcp");

pub fn main(init: std.process.Init) void {
    run(init.io, init.gpa) catch |err| mcp.reportError(err);
}

/// In-memory transport connecting a Client straight to a Server.
///
/// The client-side vtable dispatches writes into `Server.handleMessage`, and
/// the server-side vtable captures everything the server writes into `inbox`,
/// which the client side then reads back. Both ends share one buffer, so the
/// exact JSON-RPC produced by the server is what the client consumes.
const Loopback = struct {
    server: *mcp.Server,
    allocator: std.mem.Allocator,
    /// Most recent server response. Each request produces exactly one reply,
    /// so a single slot is enough and keeps ownership trivial.
    pending: ?[]u8 = null,

    fn deinit(self: *Loopback) void {
        if (self.pending) |msg| self.allocator.free(msg);
        self.pending = null;
    }

    /// Client -> server.
    fn dispatch(p: *anyopaque, io: std.Io, a: std.mem.Allocator, msg: []const u8) mcp.Transport.SendError!void {
        const self: *Loopback = @ptrCast(@alignCast(p));
        self.server.handleMessage(io, a, msg) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.WriteError,
        };
    }

    /// Server -> client. The buffer the server passes is freed as soon as `send`
    /// returns, and the allocator it hands down may be a per-request arena, so
    /// the copy is always taken from this transport's own long-lived allocator.
    fn capture(p: *anyopaque, _: std.Io, _: std.mem.Allocator, msg: []const u8) mcp.Transport.SendError!void {
        const self: *Loopback = @ptrCast(@alignCast(p));
        if (self.pending) |old| self.allocator.free(old);
        self.pending = self.allocator.dupe(u8, msg) catch return error.OutOfMemory;
    }

    fn drain(p: *anyopaque, _: std.Io, a: std.mem.Allocator) mcp.Transport.ReceiveError!?[]const u8 {
        const self: *Loopback = @ptrCast(@alignCast(p));
        const msg = self.pending orelse return null;
        self.pending = null;
        return try a.dupe(u8, msg);
    }

    fn noop(_: *anyopaque) void {}

    fn noopDestroy(_: *anyopaque, _: std.mem.Allocator) void {}

    fn clientSide(self: *Loopback) mcp.Transport {
        return .{ .ptr = self, .vtable = &.{
            .send = dispatch,
            .receive = drain,
            .close = noop,
            .destroy = noopDestroy,
        } };
    }

    fn serverSide(self: *Loopback) mcp.Transport {
        return .{ .ptr = self, .vtable = &.{
            .send = capture,
            .receive = drain,
            .close = noop,
            .destroy = noopDestroy,
        } };
    }
};

fn greetHandler(
    _: ?*anyopaque,
    _: std.Io,
    allocator: std.mem.Allocator,
    arguments: ?std.json.Value,
) mcp.tools.ToolError!mcp.ToolResult {
    var who: []const u8 = "world";
    if (arguments) |args| {
        if (args == .object) {
            if (args.object.get("name")) |n| {
                if (n == .string) who = n.string;
            }
        }
    }

    const text = try std.fmt.allocPrint(allocator, "Hello, {s}!", .{who});
    const content = try allocator.alloc(mcp.types.ContentBlock, 1);
    content[0] = .{ .text = .{ .text = text } };
    return .{ .content = content };
}

fn aboutHandler(
    _: ?*anyopaque,
    _: std.Io,
    _: std.mem.Allocator,
    uri: []const u8,
) mcp.resources.ResourceError!mcp.resources.ResourceContent {
    return .{ .uri = uri, .mimeType = "text/plain", .text = "mcp.zig round-trip server" };
}

const intro_messages = [_]mcp.PromptMessage{
    .{ .role = .user, .content = .{ .text = .{ .text = "Introduce this server." } } },
};

fn introHandler(
    _: ?*anyopaque,
    _: std.Io,
    _: std.mem.Allocator,
    _: ?std.json.Value,
) mcp.prompts.PromptError![]const mcp.PromptMessage {
    return &intro_messages;
}

/// Pops the next server response, asserting it is a successful result.
fn expectOk(
    loopback: *Loopback,
    allocator: std.mem.Allocator,
    label: []const u8,
) !std.json.Parsed(std.json.Value) {
    if (loopback.pending == null) {
        std.debug.print("  [FAIL] {s}: server sent no response\n", .{label});
        return error.NoResponse;
    }

    const msg = loopback.pending.?;
    loopback.pending = null;
    defer allocator.free(msg);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, msg, .{}) catch {
        std.debug.print("  [FAIL] {s}: malformed JSON: {s}\n", .{ label, msg });
        return error.MalformedResponse;
    };
    errdefer parsed.deinit();

    if (parsed.value != .object) {
        std.debug.print("  [FAIL] {s}: response was not a JSON-RPC object\n", .{label});
        return error.BadResponse;
    }

    if (parsed.value.object.get("error")) |err_val| {
        std.debug.print("  [FAIL] {s}: server returned an error: {s}\n", .{ label, msg });
        _ = err_val;
        return error.ServerReturnedError;
    }

    const result = parsed.value.object.get("result") orelse {
        std.debug.print("  [FAIL] {s}: response carried no result: {s}\n", .{ label, msg });
        return error.MissingResult;
    };
    if (result != .object) {
        std.debug.print("  [FAIL] {s}: result was not an object\n", .{label});
        return error.BadResult;
    }

    const result_type = if (result.object.get("resultType")) |rt| rt.string else "(absent)";
    std.debug.print("  [ok] {s:<28} resultType={s}\n", .{ label, result_type });
    return parsed;
}

fn run(io: std.Io, allocator: std.mem.Allocator) !void {
    std.debug.print("Full client/server round trip\n\n", .{});

    var server = mcp.Server.init(allocator, .{ .name = "round-trip-server", .version = "1.0.0" });
    defer server.deinit();

    try server.addTool(.{
        .name = "greet",
        .description = "Greet a user by name",
        .inputSchema = .{ .type = "object" },
        .handler = greetHandler,
    });

    try server.addResource(.{
        .uri = "info://server/about",
        .name = "About",
        .description = "Information about this server",
        .mimeType = "text/plain",
        .handler = aboutHandler,
    });

    try server.addPrompt(.{
        .name = "introduce",
        .description = "Ask the model to introduce this server",
        .handler = introHandler,
    });

    var loopback = Loopback{ .server = &server, .allocator = allocator };
    defer loopback.deinit();
    server.transport = loopback.serverSide();

    var client = mcp.Client.init(io, allocator, .{ .name = "round-trip-client", .version = "1.0.0" });
    defer client.deinit();
    client.transport = loopback.clientSide();

    // Discovery and list operations
    std.debug.print("Discovery and lists:\n", .{});

    try client.discover();
    {
        var parsed = try expectOk(&loopback, allocator, "server/discover");
        defer parsed.deinit();
        const result = parsed.value.object.get("result").?.object;
        if (result.get("capabilities") == null) {
            std.debug.print("  [FAIL] server/discover: no capabilities\n", .{});
            return error.MissingCapabilities;
        }
    }

    try client.listTools();
    {
        var parsed = try expectOk(&loopback, allocator, "tools/list");
        defer parsed.deinit();
        const tools_arr = parsed.value.object.get("result").?.object.get("tools").?.array;
        if (tools_arr.items.len == 0) {
            std.debug.print("  [FAIL] tools/list: server advertised no tools\n", .{});
            return error.EmptyToolList;
        }
        std.debug.print("       -> {d} tool(s): {s}\n", .{ tools_arr.items.len, tools_arr.items[0].object.get("name").?.string });
    }

    try client.listResources();
    {
        var parsed = try expectOk(&loopback, allocator, "resources/list");
        defer parsed.deinit();
        const list = parsed.value.object.get("result").?.object.get("resources").?.array;
        if (list.items.len == 0) {
            std.debug.print("  [FAIL] resources/list: server advertised no resources\n", .{});
            return error.EmptyResourceList;
        }
        std.debug.print("       -> {d} resource(s): {s}\n", .{ list.items.len, list.items[0].object.get("uri").?.string });
    }

    try client.listPrompts();
    {
        var parsed = try expectOk(&loopback, allocator, "prompts/list");
        defer parsed.deinit();
        const list = parsed.value.object.get("result").?.object.get("prompts").?.array;
        if (list.items.len == 0) {
            std.debug.print("  [FAIL] prompts/list: server advertised no prompts\n", .{});
            return error.EmptyPromptList;
        }
        std.debug.print("       -> {d} prompt(s): {s}\n", .{ list.items.len, list.items[0].object.get("name").?.string });
    }

    // Data-plane operations: these were never covered by the other examples
    std.debug.print("\nData plane (tools/call, resources/read, prompts/get):\n", .{});

    var greet_args: std.json.ObjectMap = .empty;
    defer greet_args.deinit(allocator);
    try greet_args.put(allocator, "name", .{ .string = "Zig" });

    try client.callTool("greet", .{ .object = greet_args });
    {
        var parsed = try expectOk(&loopback, allocator, "tools/call greet");
        defer parsed.deinit();
        const result = parsed.value.object.get("result").?.object;
        const text = result.get("content").?.array.items[0].object.get("text").?.string;
        if (!std.mem.startsWith(u8, text, "Hello, Zig!")) {
            std.debug.print("  [FAIL] tools/call: unexpected tool output: {s}\n", .{text});
            return error.UnexpectedToolOutput;
        }
        std.debug.print("       -> tool returned: {s}\n", .{text});
    }

    try client.readResource("info://server/about");
    {
        var parsed = try expectOk(&loopback, allocator, "resources/read about");
        defer parsed.deinit();
        const contents = parsed.value.object.get("result").?.object.get("contents").?.array;
        const text = contents.items[0].object.get("text").?.string;
        std.debug.print("       -> resource returned: {s}\n", .{text});
    }

    try client.getPrompt("introduce", null);
    {
        var parsed = try expectOk(&loopback, allocator, "prompts/get introduce");
        defer parsed.deinit();
        const messages = parsed.value.object.get("result").?.object.get("messages").?.array;
        std.debug.print("       -> prompt returned {d} message(s)\n", .{messages.items.len});
    }

    std.debug.print("\nAll client/server operations completed successfully.\n", .{});
}
