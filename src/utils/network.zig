//! Network Utilities
//!
//! Provides network connectivity utilities used by the update checker and
//! logging helpers. HTTP is handled exclusively by httpx.zig so the whole
//! project shares one HTTP stack; everything else comes from std.

const std = @import("std");
const httpx = @import("httpx");
const builtin = @import("builtin");

pub const NetworkError = error{
    InvalidUri,
    ConnectionFailed,
    SocketCreationError,
    AddressResolutionError,
    RequestFailed,
    UnsupportedEncoding,
    ReadError,
};

/// Fetches a JSON response from a URL using httpx.zig.
/// Returns the parsed JSON value (caller must deinit).
pub fn fetchJson(
    io: std.Io,
    allocator: std.mem.Allocator,
    url: []const u8,
    headers: []const httpx.Header,
) !std.json.Parsed(std.json.Value) {
    var client = httpx.Client.init(allocator, io, .{});
    defer client.deinit();

    var all_headers: std.ArrayList(httpx.Header) = .empty;
    defer all_headers.deinit(allocator);

    try all_headers.append(allocator, .{
        .name = "User-Agent",
        .value = std.fmt.comptimePrint("mcp.zig/{s}", .{builtin.zig_version_string}),
    });
    try all_headers.appendSlice(allocator, headers);

    var response = client.get(url, .{ .headers = all_headers.items }) catch {
        return NetworkError.RequestFailed;
    };
    defer response.deinit();

    if (response.status >= 400) return NetworkError.RequestFailed;

    // httpx owns the response body; parsing copies the strings it needs, so
    // the body buffer does not have to outlive this call.
    return std.json.parseFromSlice(std.json.Value, allocator, response.text(), .{}) catch {
        return NetworkError.ReadError;
    };
}
