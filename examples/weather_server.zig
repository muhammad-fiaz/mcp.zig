//! Weather Server Example
//!
//! This example replicates the weather server from the MCP documentation,
//! demonstrating how to create a practical MCP server.

const std = @import("std");
const mcp = @import("mcp");

const NWS_API_BASE = "https://api.weather.gov";

pub fn main() void {
    run() catch |err| {
        mcp.reportError(err);
    };
}

fn run() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create weather server
    var server = mcp.Server.init(.{
        .name = "weather-server",
        .version = "1.0.0",
        .title = "Weather Server",
        .description = "Get weather alerts and forecasts for US locations",
        .instructions = "Use get_alerts to check weather alerts for a US state, or get_forecast to get the forecast for a location.",
        .allocator = allocator,
    });
    defer server.deinit();

    // Add get_alerts tool
    try server.addTool(.{
        .name = "get_alerts",
        .description = "Get weather alerts for a US state",
        .title = "Get Weather Alerts",
        .handler = getAlertsHandler,
    });

    // Add get_forecast tool
    try server.addTool(.{
        .name = "get_forecast",
        .description = "Get weather forecast for a location",
        .title = "Get Weather Forecast",
        .handler = getForecastHandler,
    });

    // Add a weather info resource
    try server.addResource(.{
        .uri = "weather://info",
        .name = "Weather API Info",
        .description = "Information about the weather data source",
        .mimeType = "text/plain",
        .handler = weatherInfoHandler,
    });

    // Add resource template for state alerts
    try server.addResourceTemplate(.{
        .uriTemplate = "weather://alerts/{state}",
        .name = "state-alerts",
        .title = "State Weather Alerts",
        .description = "Get weather alerts for a specific US state",
        .mimeType = "application/json",
    });

    // Enable logging and completions
    server.enableLogging();
    server.enableCompletions();

    // Run the server
    try server.run(.stdio);
}

fn getAlertsHandler(allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const state = mcp.tools.getString(args, "state") orelse {
        return mcp.tools.errorResult(allocator, "Missing required argument: state (two-letter US state code)") catch return mcp.tools.ToolError.OutOfMemory;
    };

    // Validate state code
    if (state.len != 2) {
        return mcp.tools.errorResult(allocator, "State must be a two-letter code (e.g., CA, NY, TX)") catch return mcp.tools.ToolError.OutOfMemory;
    }

    // In a real implementation, we would make an HTTP request to:
    // {NWS_API_BASE}/alerts/active/area/{state}
    // For this example, we return mock data

    var buf: [1024]u8 = undefined;
    const result = std.fmt.bufPrint(&buf,
        \\Weather Alerts for {s}:
        \\
        \\No active alerts at this time.
        \\
        \\Note: This is a demo. In production, this would fetch real data from:
        \\{s}/alerts/active/area/{s}
    , .{ state, NWS_API_BASE, state }) catch "Error formatting response";

    return mcp.tools.textResult(allocator, result) catch return mcp.tools.ToolError.OutOfMemory;
}

fn getForecastHandler(allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const lat = mcp.tools.getFloat(args, "latitude") orelse {
        return mcp.tools.errorResult(allocator, "Missing required argument: latitude") catch return mcp.tools.ToolError.OutOfMemory;
    };

    const lon = mcp.tools.getFloat(args, "longitude") orelse {
        return mcp.tools.errorResult(allocator, "Missing required argument: longitude") catch return mcp.tools.ToolError.OutOfMemory;
    };

    // Validate coordinates
    if (lat < -90 or lat > 90) {
        return mcp.tools.errorResult(allocator, "Latitude must be between -90 and 90") catch return mcp.tools.ToolError.OutOfMemory;
    }
    if (lon < -180 or lon > 180) {
        return mcp.tools.errorResult(allocator, "Longitude must be between -180 and 180") catch return mcp.tools.ToolError.OutOfMemory;
    }

    var buf: [2048]u8 = undefined;
    const result = std.fmt.bufPrint(&buf,
        \\Weather Forecast for ({d:.4}, {d:.4}):
        \\
        \\Today:
        \\  Temperature: 72°F
        \\  Wind: 5 mph NW
        \\  Conditions: Partly cloudy
        \\
        \\Tonight:
        \\  Temperature: 55°F
        \\  Wind: 3 mph W
        \\  Conditions: Clear
        \\
        \\Tomorrow:
        \\  Temperature: 75°F
        \\  Wind: 8 mph SW
        \\  Conditions: Sunny
        \\
        \\Note: This is demo data. Production would fetch from:
        \\{s}/points/{d:.4},{d:.4}
    , .{ lat, lon, NWS_API_BASE, lat, lon }) catch "Error formatting response";

    return mcp.tools.textResult(allocator, result) catch return mcp.tools.ToolError.OutOfMemory;
}

fn weatherInfoHandler(_: std.mem.Allocator, uri: []const u8) mcp.resources.ResourceError!mcp.resources.ResourceContent {
    return .{
        .uri = uri,
        .mimeType = "text/plain",
        .text =
        \\Weather Server - Data Source Information
        \\
        \\This server uses the National Weather Service API.
        \\API Base URL: https://api.weather.gov
        \\
        \\Available Tools:
        \\- get_alerts: Get active weather alerts for a US state
        \\- get_forecast: Get weather forecast for coordinates
        \\
        \\Note: Only US locations are supported.
        ,
    };
}
