//! Network Utilities
//!
//! Provides network connectivity utilities including HTTP JSON fetching and TCP/UDP socket creation.
//! Used primarily for update checking and logging.

const std = @import("std");
const http = std.http;
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

/// Fetches a JSON response from a URL.
/// Returns the parsed JSON value (caller must deinit).
pub fn fetchJson(io: std.Io, allocator: std.mem.Allocator, url: []const u8, headers: []const http.Header) !std.json.Parsed(std.json.Value) {
    var client: http.Client = .{
        .allocator = allocator,
        .io = io,
    };
    defer client.deinit();

    var req = try client.request(.GET, try std.Uri.parse(url), .{
        .headers = .{ .user_agent = .{ .override = std.fmt.comptimePrint("mcp.zig/{s}", .{builtin.zig_version_string}) } },
        .extra_headers = headers,
    });
    defer req.deinit();

    try req.sendBodiless();

    const redirect_buffer = try allocator.alloc(u8, 8 * 1024);
    defer allocator.free(redirect_buffer);

    var response = try req.receiveHead(redirect_buffer);
    if (response.head.status != .ok) return NetworkError.RequestFailed;

    const decompress_buffer: []u8 = switch (response.head.content_encoding) {
        .identity => &.{},
        .zstd => try allocator.alloc(u8, std.compress.zstd.default_window_len),
        .deflate, .gzip => try allocator.alloc(u8, std.compress.flate.max_window_len),
        .compress => return NetworkError.UnsupportedEncoding,
    };
    defer if (decompress_buffer.len != 0) allocator.free(decompress_buffer);

    var transfer_buffer: [64]u8 = undefined;
    var decompress: http.Decompress = undefined;
    var reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);

    var body = std.ArrayList(u8).initCapacity(allocator, 4096) catch return NetworkError.ReadError;
    defer body.deinit(allocator);

    var buf: [4096]u8 = undefined;
    while (true) {
        const n = reader.readSliceShort(&buf) catch return NetworkError.ReadError;
        if (n == 0) break;
        body.appendSlice(allocator, buf[0..n]) catch return NetworkError.ReadError;
    }

    // Parse JSON from the response body.
    // std.json.parseFromSlice allocates copies of strings by default, so it's safe to free body.
    return std.json.parseFromSlice(std.json.Value, allocator, body.items, .{});
}
