//! MCP Apps Server Example
//!
//! Demonstrates the MCP Apps UI Extension (`io.modelcontextprotocol/ui`).
//!
//! MCP Apps allow servers to provide interactive graphical user interfaces (GUIs)
//! to AI client hosts (such as Claude Desktop, Zed, Goose, or web-based MCP hosts).
//!
//! Key components demonstrated:
//! 1. Enabling the UI extension on the server via `server.enableUi()`.
//!    During `server/discover`, the server advertises `io.modelcontextprotocol/ui`
//!    in its `capabilities.extensions`.
//! 2. Declaring UI resources with MIME type `text/html;profile=mcp-app` (`mcp.MIME_TYPE_MCP_APP`),
//!    built conveniently with `mcp.ResourceBuilder.mcpApp()`.
//! 3. Linking tools to UI resources using `_meta.ui.resourceUri`, built with
//!    `ToolBuilder.ui()` and `ToolBuilder.uiWithVisibility()`.
//! 4. Returning tool call results that carry UI metadata using `mcp.uiResult()`.
//! 5. Supporting both STDIO transport (default, for host integration) and
//!    HTTP transport (via `--http` flag, for browser and curl testing).
//!
//! Run with STDIO (default):
//!   zig build run-mcp-app
//!
//! Run with HTTP on port 8080:
//!   zig build run-mcp-app -- --http
//!   # or with custom port:
//!   zig build run-mcp-app -- --http --port 8085

const std = @import("std");
const mcp = @import("mcp");

/// Application state shared with tool and resource handlers.
const AppState = struct {
    requests_handled: usize = 0,
    active_users: usize = 42,
    cpu_load_pct: usize = 18,
    memory_mb: usize = 256,
};

var global_state: AppState = .{};

pub fn main(init: std.process.Init) void {
    run(init.io, init.gpa, init.minimal.args) catch |err| {
        mcp.reportError(err);
    };
}

fn run(io: std.Io, allocator: std.mem.Allocator, process_args: std.process.Args) !void {
    var args = try std.process.Args.Iterator.initAllocator(process_args, allocator);
    defer args.deinit();

    _ = args.next(); // Skip executable path
    var use_http = false;
    var http_port: u16 = 8080;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--http")) {
            use_http = true;
        } else if (std.mem.eql(u8, arg, "--port")) {
            if (args.next()) |port_str| {
                http_port = std.fmt.parseInt(u16, port_str, 10) catch 8080;
            }
        }
    }

    var schema_arena = std.heap.ArenaAllocator.init(allocator);
    defer schema_arena.deinit();
    const sa = schema_arena.allocator();

    const metric_schema = try buildMetricSchema(sa);

    var server = mcp.Server.init(allocator, .{
        .name = "mcp-apps-server",
        .version = "1.0.0",
        .title = "MCP Apps Interactive Server",
        .description = "Demonstrates interactive UI applications via the MCP Apps UI extension",
        .instructions = "Use 'open_dashboard' to launch the interactive UI, or 'update_metric' to adjust values.",
    });
    defer server.deinit();

    // 1. Enable MCP Apps UI extension negotiation.
    // This advertises `io.modelcontextprotocol/ui` in capabilities.extensions during server/discover.
    try server.enableUi();
    server.enableLogging();

    // 2. Register UI resources.
    // Resources return standalone HTML pages with MIME type `text/html;profile=mcp-app`.
    var dash_res_builder = mcp.ResourceBuilder.init("ui://dashboard/interactive", "Interactive Dashboard");
    _ = dash_res_builder
        .title("System & Metrics Dashboard")
        .description("Self-contained interactive dashboard for monitoring system health and metrics")
        .mcpApp()
        .handler(dashboardResourceHandler);
    try server.addResource(dash_res_builder.build());

    var analytics_res_builder = mcp.ResourceBuilder.init("ui://analytics/summary", "Analytics Summary");
    _ = analytics_res_builder
        .title("Usage Analytics")
        .description("Summary charts and usage statistics")
        .mcpApp()
        .handler(analyticsResourceHandler);
    try server.addResource(analytics_res_builder.build());

    // 3. Register Tools linked to the UI resources via `_meta.ui`.
    // The client host application uses `_meta.ui.resourceUri` to automatically render
    // the appropriate view alongside or in place of standard tool responses.
    var open_dash_builder = mcp.ToolBuilder.init("open_dashboard");
    _ = try open_dash_builder
        .title("Open Interactive Dashboard")
        .description("Launches the interactive real-time system metrics dashboard")
        .readOnly()
        .idempotent()
        .ui(sa, "ui://dashboard/interactive");
    _ = open_dash_builder.handler(openDashboardHandler);
    try server.addTool(open_dash_builder.build());

    var update_metric_builder = mcp.ToolBuilder.init("update_metric");
    _ = try update_metric_builder
        .title("Update System Metric")
        .description("Updates a dashboard metric value (active_users, cpu_load_pct, or memory_mb)")
        .inputSchema(metric_schema)
        .uiWithVisibility(sa, "ui://dashboard/interactive", &[_][]const u8{ "model", "app" });
    _ = update_metric_builder.handler(updateMetricHandler);
    try server.addTool(update_metric_builder.build());

    if (use_http) {
        std.debug.print("MCP Apps Server running on http://127.0.0.1:{d}\n", .{http_port});
        std.debug.print("  Discovery: POST http://127.0.0.1:{d}/mcp (method: server/discover)\n", .{http_port});
        std.debug.print("  Read UI:   POST http://127.0.0.1:{d}/mcp (method: resources/read, uri: ui://dashboard/interactive)\n", .{http_port});
        try server.run(io, allocator, .{ .http = .{ .host = "127.0.0.1", .port = http_port } });
    } else {
        std.debug.print("MCP Apps Server running on STDIO. Connect from Claude Desktop, Zed, or MCP Inspector.\n", .{});
        try server.run(io, allocator, .stdio);
    }
}

// ---------------------------------------------------------------------------
// Tool Handlers
// ---------------------------------------------------------------------------

fn openDashboardHandler(
    _: ?*anyopaque,
    _: std.Io,
    allocator: std.mem.Allocator,
    _: ?std.json.Value,
) mcp.tools.ToolError!mcp.ToolResult {
    global_state.requests_handled += 1;
    // Returns a ToolResult carrying `_meta.ui.resourceUri` pointing to the UI resource.
    return mcp.uiResult(
        allocator,
        "ui://dashboard/interactive",
        "Dashboard ready. The interactive UI is rendered in the MCP Apps viewport.",
    ) catch return mcp.tools.ToolError.OutOfMemory;
}

fn updateMetricHandler(
    _: ?*anyopaque,
    _: std.Io,
    allocator: std.mem.Allocator,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.ToolResult {
    global_state.requests_handled += 1;

    const metric_name = mcp.tools.getString(args, "name") orelse return mcp.tools.ToolError.InvalidArguments;
    const value = mcp.tools.getInteger(args, "value") orelse return mcp.tools.ToolError.InvalidArguments;

    if (value < 0) return mcp.tools.ToolError.InvalidArguments;
    const val_u: usize = @intCast(value);

    if (std.mem.eql(u8, metric_name, "active_users")) {
        global_state.active_users = val_u;
    } else if (std.mem.eql(u8, metric_name, "cpu_load_pct")) {
        global_state.cpu_load_pct = @min(val_u, 100);
    } else if (std.mem.eql(u8, metric_name, "memory_mb")) {
        global_state.memory_mb = val_u;
    } else {
        return mcp.tools.ToolError.InvalidArguments;
    }

    const msg = try std.fmt.allocPrint(allocator, "Metric '{s}' updated to {d}.", .{ metric_name, value });
    return mcp.uiResult(
        allocator,
        "ui://dashboard/interactive",
        msg,
    ) catch return mcp.tools.ToolError.OutOfMemory;
}

// ---------------------------------------------------------------------------
// Resource Handlers
// ---------------------------------------------------------------------------

fn dashboardResourceHandler(
    _: ?*anyopaque,
    _: std.Io,
    allocator: std.mem.Allocator,
    uri: []const u8,
) mcp.resources.ResourceError!mcp.ResourceContent {
    // Generate an interactive HTML document adhering to the MCP Apps profile.
    const html = std.fmt.allocPrint(allocator,
        \\<!DOCTYPE html>
        \\<html lang="en">
        \\<head>
        \\  <meta charset="UTF-8" />
        \\  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
        \\  <title>MCP App — System Dashboard</title>
        \\  <style>
        \\    :root {{
        \\      --bg: #0f172a;
        \\      --card-bg: #1e293b;
        \\      --accent: #38bdf8;
        \\      --accent-glow: rgba(56, 189, 248, 0.25);
        \\      --text: #f8fafc;
        \\      --text-muted: #94a3b8;
        \\      --border: #334155;
        \\      --success: #34d399;
        \\    }}
        \\    body {{
        \\      margin: 0;
        \\      padding: 24px;
        \\      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
        \\      background-color: var(--bg);
        \\      color: var(--text);
        \\      box-sizing: border-box;
        \\    }}
        \\    .header {{
        \\      display: flex;
        \\      justify-content: space-between;
        \\      align-items: center;
        \\      margin-bottom: 24px;
        \\      padding-bottom: 16px;
        \\      border-bottom: 1px solid var(--border);
        \\    }}
        \\    .title {{
        \\      font-size: 20px;
        \\      font-weight: 700;
        \\      color: var(--text);
        \\      display: flex;
        \\      align-items: center;
        \\      gap: 10px;
        \\    }}
        \\    .badge {{
        \\      font-size: 11px;
        \\      text-transform: uppercase;
        \\      letter-spacing: 0.05em;
        \\      padding: 4px 8px;
        \\      border-radius: 9999px;
        \\      background: var(--accent-glow);
        \\      color: var(--accent);
        \\      border: 1px solid var(--accent);
        \\    }}
        \\    .grid {{
        \\      display: grid;
        \\      grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
        \\      gap: 16px;
        \\      margin-bottom: 24px;
        \\    }}
        \\    .card {{
        \\      background: var(--card-bg);
        \\      border: 1px solid var(--border);
        \\      border-radius: 12px;
        \\      padding: 18px;
        \\      display: flex;
        \\      flex-direction: column;
        \\      gap: 8px;
        \\      transition: transform 0.15s ease, border-color 0.15s ease;
        \\    }}
        \\    .card:hover {{
        \\      transform: translateY(-2px);
        \\      border-color: var(--accent);
        \\    }}
        \\    .card-label {{
        \\      font-size: 13px;
        \\      color: var(--text-muted);
        \\    }}
        \\    .card-value {{
        \\      font-size: 26px;
        \\      font-weight: 700;
        \\      color: var(--text);
        \\    }}
        \\    .progress-bar {{
        \\      width: 100%;
        \\      height: 6px;
        \\      background: #334155;
        \\      border-radius: 3px;
        \\      overflow: hidden;
        \\      margin-top: 6px;
        \\    }}
        \\    .progress-fill {{
        \\      height: 100%;
        \\      background: var(--accent);
        \\      transition: width 0.3s ease;
        \\    }}
        \\    .controls {{
        \\      background: var(--card-bg);
        \\      border: 1px solid var(--border);
        \\      border-radius: 12px;
        \\      padding: 18px;
        \\    }}
        \\    .btn {{
        \\      background: var(--accent);
        \\      color: #0f172a;
        \\      border: none;
        \\      padding: 10px 16px;
        \\      border-radius: 8px;
        \\      font-weight: 600;
        \\      cursor: pointer;
        \\      transition: opacity 0.15s ease;
        \\    }}
        \\    .btn:hover {{ opacity: 0.9; }}
        \\  </style>
        \\</head>
        \\<body>
        \\  <div class="header">
        \\    <div class="title">
        \\      <span>MCP Apps System Dashboard</span>
        \\      <span class="badge">Live App</span>
        \\    </div>
        \\    <div style="font-size: 13px; color: var(--text-muted);">Protocol 2026-07-28</div>
        \\  </div>
        \\
        \\  <div class="grid">
        \\    <div class="card">
        \\      <div class="card-label">Active Users</div>
        \\      <div class="card-value" id="val-users">{d}</div>
        \\    </div>
        \\    <div class="card">
        \\      <div class="card-label">CPU Utilization</div>
        \\      <div class="card-value" id="val-cpu">{d}%</div>
        \\      <div class="progress-bar"><div class="progress-fill" style="width: {d}%;"></div></div>
        \\    </div>
        \\    <div class="card">
        \\      <div class="card-label">Memory Usage</div>
        \\      <div class="card-value" id="val-mem">{d} MB</div>
        \\    </div>
        \\    <div class="card">
        \\      <div class="card-label">Requests Handled</div>
        \\      <div class="card-value" id="val-reqs">{d}</div>
        \\    </div>
        \\  </div>
        \\
        \\  <div class="controls">
        \\    <h3 style="margin-top: 0; font-size: 15px;">Interactive Controls</h3>
        \\    <p style="font-size: 13px; color: var(--text-muted); margin-bottom: 12px;">
        \\      This UI is rendered in a sandboxed iframe. AI host applications can interact with the server using standard MCP tools.
        \\    </p>
        \\    <button class="btn" onclick="alert('MCP App interaction event!')">Simulate UI Action</button>
        \\  </div>
        \\</body>
        \\</html>
    , .{
        global_state.active_users,
        global_state.cpu_load_pct,
        global_state.cpu_load_pct,
        global_state.memory_mb,
        global_state.requests_handled,
    }) catch return mcp.resources.ResourceError.OutOfMemory;

    return .{
        .uri = uri,
        .mimeType = mcp.MIME_TYPE_MCP_APP,
        .text = html,
    };
}

fn analyticsResourceHandler(
    _: ?*anyopaque,
    _: std.Io,
    allocator: std.mem.Allocator,
    uri: []const u8,
) mcp.resources.ResourceError!mcp.ResourceContent {
    const html = std.fmt.allocPrint(allocator,
        \\<!DOCTYPE html>
        \\<html lang="en">
        \\<head>
        \\  <meta charset="UTF-8" />
        \\  <title>MCP App — Analytics Summary</title>
        \\  <style>
        \\    body {{
        \\      margin: 0;
        \\      padding: 20px;
        \\      background: #090d16;
        \\      color: #e2e8f0;
        \\      font-family: sans-serif;
        \\    }}
        \\    h2 {{ color: #38bdf8; }}
        \\  </style>
        \\</head>
        \\<body>
        \\  <h2>Analytics Overview</h2>
        \\  <p>Total processed requests: {d}</p>
        \\</body>
        \\</html>
    , .{global_state.requests_handled}) catch return mcp.resources.ResourceError.OutOfMemory;

    return .{
        .uri = uri,
        .mimeType = mcp.MIME_TYPE_MCP_APP,
        .text = html,
    };
}

// ---------------------------------------------------------------------------
// Schemas
// ---------------------------------------------------------------------------

fn buildMetricSchema(allocator: std.mem.Allocator) !mcp.types.InputSchema {
    var b = mcp.schema.InputSchemaBuilder.init(allocator);
    defer b.deinit(allocator);
    _ = b.setSchemaDialect("https://json-schema.org/draft/2020-12/schema");
    _ = try b.addString(allocator, "name", "The metric to update: 'active_users', 'cpu_load_pct', or 'memory_mb'", true);
    _ = try b.addInteger(allocator, "value", "The new integer value for the metric", true);
    return b.toInputSchema(allocator);
}
