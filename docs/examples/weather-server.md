---
title: "Weather Server Example"
description: "Build an MCP weather server with forecast and alert tools using MCP.zig."
keywords: [weather server, weather API, forecast, alerts, resource templates, input validation]
---

# Weather Server Example

A full MCP server example with validation, resources, templates, and realistic weather tool contracts.

## Overview

This example demonstrates:

- Argument validation for tool inputs
- Multiple tools with focused responsibilities
- Resource and resource-template registration
- Capability toggles (logging, completions, tasks)
- InputSchema constraints (property length, range)

## Full Source Code

```zig
const std = @import("std");
const mcp = @import("mcp");

const NWS_API_BASE = "https://api.weather.gov";

pub fn main(init: std.process.Init) void {
    run(init.io, init.gpa) catch |err| mcp.reportError(err);
}

fn run(io: std.Io, allocator: std.mem.Allocator) !void {
    var sa_arena = std.heap.ArenaAllocator.init(allocator);
    defer sa_arena.deinit();
    const sa = sa_arena.allocator();

    const alerts_schema = try buildAlertsSchema(sa);
    const forecast_schema = try buildForecastSchema(sa);

    var server = mcp.Server.init(allocator, .{
        .name = "weather-server",
        .version = "1.0.0",
        .title = "Weather Server",
        .description = "Get weather alerts and forecasts for US locations",
        .instructions = "Use get_alerts with a 2-letter state code, or get_forecast with lat/lon.",
    });
    defer server.deinit();

    const ro: mcp.tools.ToolAnnotations = .{
        .readOnlyHint = true,
        .idempotentHint = true,
        .openWorldHint = true,
    };

    try server.addTool(.{
        .name = "get_alerts",
        .description = "Get active weather alerts for a US state",
        .title = "Get Weather Alerts",
        .inputSchema = alerts_schema,
        .annotations = ro,
        .handler = getAlertsHandler,
    });
    try server.addTool(.{
        .name = "get_forecast",
        .description = "Get a 3-day weather forecast for a lat/lon coordinate",
        .title = "Get Weather Forecast",
        .inputSchema = forecast_schema,
        .annotations = ro,
        .handler = getForecastHandler,
    });
    try server.addResource(.{
        .uri = "weather://info",
        .name = "Weather API Info",
        .description = "About the data source",
        .mimeType = "text/plain",
        .annotations = .{ .priority = 0.7 },
        .handler = weatherInfoHandler,
    });
    try server.addResourceTemplate(.{
        .uriTemplate = "weather://alerts/{state}",
        .name = "state-alerts",
        .title = "State Weather Alerts",
        .description = "Active alerts for a specific US state (replace {state} with 2-letter code)",
        .mimeType = "application/json",
    });

    server.enableLogging();
    server.enableCompletions();
    server.enableTasks();
    try server.run(io, allocator, .stdio);
}

fn buildAlertsSchema(allocator: std.mem.Allocator) !mcp.types.InputSchema {
    var b = mcp.schema.InputSchemaBuilder.init(allocator);
    defer b.deinit(allocator);
    _ = b.setSchemaDialect("https://json-schema.org/draft/2020-12/schema");
    _ = try b.addString(allocator, "state", "Two-letter US state code (e.g. CA, NY, TX)", true);
    _ = b.setPropertyLength("state", 2, 2);
    return b.toInputSchema(allocator);
}

fn buildForecastSchema(allocator: std.mem.Allocator) !mcp.types.InputSchema {
    var b = mcp.schema.InputSchemaBuilder.init(allocator);
    defer b.deinit(allocator);
    _ = b.setSchemaDialect("https://json-schema.org/draft/2020-12/schema");
    _ = try b.addNumber(allocator, "latitude", "Latitude in decimal degrees (-90 to 90)", true);
    _ = try b.addNumber(allocator, "longitude", "Longitude in decimal degrees (-180 to 180)", true);
    _ = b.setPropertyRange("latitude", -90, 90);
    _ = b.setPropertyRange("longitude", -180, 180);
    return b.toInputSchema(allocator);
}

fn getAlertsHandler(_: ?*anyopaque, _: std.Io, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const state = mcp.tools.getString(args, "state") orelse
        return mcp.tools.errorResult(allocator, "Missing required argument: state") catch return mcp.tools.ToolError.OutOfMemory;
    if (state.len != 2)
        return mcp.tools.errorResult(allocator, "State must be a two-letter code (e.g. CA)") catch return mcp.tools.ToolError.OutOfMemory;
    var buf: [1024]u8 = undefined;
    const result = std.fmt.bufPrint(&buf,
        \\Weather Alerts for {s}:
        \\No active alerts at this time.
        \\[Demo — production fetches from {s}/alerts/active/area/{s}]
    , .{ state, NWS_API_BASE, state }) catch "Error formatting response";
    return mcp.tools.textResult(allocator, result) catch return mcp.tools.ToolError.OutOfMemory;
}

fn getForecastHandler(_: ?*anyopaque, _: std.Io, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const lat = mcp.tools.getFloat(args, "latitude") orelse
        return mcp.tools.errorResult(allocator, "Missing required argument: latitude") catch return mcp.tools.ToolError.OutOfMemory;
    const lon = mcp.tools.getFloat(args, "longitude") orelse
        return mcp.tools.errorResult(allocator, "Missing required argument: longitude") catch return mcp.tools.ToolError.OutOfMemory;
    if (lat < -90 or lat > 90)
        return mcp.tools.errorResult(allocator, "Latitude must be -90..90") catch return mcp.tools.ToolError.OutOfMemory;
    if (lon < -180 or lon > 180)
        return mcp.tools.errorResult(allocator, "Longitude must be -180..180") catch return mcp.tools.ToolError.OutOfMemory;
    var buf: [2048]u8 = undefined;
    const result = std.fmt.bufPrint(&buf,
        \\Forecast for ({d:.4}, {d:.4}):
        \\Today:    72F / Partly cloudy
        \\Tonight:  55F / Clear
        \\Tomorrow: 75F / Sunny
        \\[Demo — production fetches from {s}/points/{d:.4},{d:.4}]
    , .{ lat, lon, NWS_API_BASE, lat, lon }) catch "Error formatting response";
    return mcp.tools.textResult(allocator, result) catch return mcp.tools.ToolError.OutOfMemory;
}

fn weatherInfoHandler(_: ?*anyopaque, _: std.Io, _: std.mem.Allocator, uri: []const u8) mcp.resources.ResourceError!mcp.resources.ResourceContent {
    return .{
        .uri = uri,
        .mimeType = "text/plain",
        .text =
        \\Weather Server — Data Source Information
        \\Provider: National Weather Service (NWS)
        \\API:      https://api.weather.gov
        \\Coverage: United States only
        \\Tools:    get_alerts, get_forecast
        ,
    };
}
```

## Build and Run

```bash
zig build
./zig-out/bin/weather-server
```

PowerShell (Windows):

```powershell
zig build
.\zig-out\bin\weather-server.exe
```

## Client Usage

### Get Alerts for California

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_alerts","arguments":{"state":"CA"}}}' | ./zig-out/bin/weather-server
```

### Get Forecast for San Francisco

```bash
echo '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_forecast","arguments":{"latitude":37.7749,"longitude":-122.4194}}}' | ./zig-out/bin/weather-server
```

PowerShell:

```powershell
'{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_alerts","arguments":{"state":"CA"}}}' | .\zig-out\bin\weather-server.exe
```

## Expected Output

**get_alerts("CA"):**

```json
{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"Weather Alerts for CA:\nNo active alerts at this time.\n[Demo — production fetches from https://api.weather.gov/alerts/active/area/CA]"}],"isError":false,"resultType":"complete","structuredContent":{"text":"Weather Alerts for CA:\nNo active alerts at this time.\n[Demo — production fetches from https://api.weather.gov/alerts/active/area/CA]"}}}
```

**get_forecast(37.7749, -122.4194):**

```json
{"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"Forecast for (37.7749, -122.4194):\nToday:    72F / Partly cloudy\nTonight:  55F / Clear\nTomorrow: 75F / Sunny\n[Demo — production fetches from https://api.weather.gov/points/37.7749,-122.4194]"}],"isError":false,"resultType":"complete","structuredContent":{"text":"Forecast for (37.7749, -122.4194):\nToday:    72F / Partly cloudy\nTonight:  55F / Clear\nTomorrow: 75F / Sunny\n[Demo — production fetches from https://api.weather.gov/points/37.7749,-122.4194]"}}}
```

## Output Behavior

- Invalid state/coordinates return MCP error results
- Valid inputs return formatted text output payloads
- Resource reads return weather API information text

## Next Steps

- [Tools Guide](/guide/tools)
- [Resources Guide](/guide/resources)
- [Calculator Server](/examples/calculator-server)
