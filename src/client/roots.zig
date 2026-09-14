//! MCP Roots Module (Spec 2026-07-28, deprecated but functional)
//!
//! Provides types and utilities for filesystem roots. Roots define the
//! boundaries within which a server may operate on the client's filesystem,
//! enabling secure and scoped file access.

const std = @import("std");
const types = @import("../protocol/types.zig");

/// A filesystem root that can be exposed to servers.
pub const Root = types.Root;

/// Result of listing available roots.
pub const RootsListResult = struct {
    _meta: ?std.json.Value = null,
    roots: []const Root,
};

/// Creates a root from a filesystem path without allocating.
///
/// If `path` already uses `file://`, it is returned unchanged.
/// Otherwise this returns `path` as-is. Use `fileRootAlloc` when you need
/// a canonical `file://` URI from a plain filesystem path.
pub fn fileRoot(path: []const u8, name: ?[]const u8) Root {
    if (std.mem.startsWith(u8, path, "file://")) {
        return .{ .uri = path, .name = name };
    }
    return .{ .uri = path, .name = name };
}

/// Creates a canonical `file://` root URI by allocating the URI string.
pub fn fileRootAlloc(allocator: std.mem.Allocator, path: []const u8, name: ?[]const u8) !Root {
    if (std.mem.startsWith(u8, path, "file://")) {
        return .{ .uri = try allocator.dupe(u8, path), .name = name };
    }
    const uri = try std.fmt.allocPrint(allocator, "file://{s}", .{path});
    return .{ .uri = uri, .name = name };
}

/// Frees URI memory allocated by `fileRootAlloc`.
pub fn deinitAllocatedRoot(allocator: std.mem.Allocator, r: *Root) void {
    allocator.free(r.uri);
}

/// Creates a root with a pre-formed URI.
pub fn root(uri: []const u8, name: ?[]const u8) Root {
    return .{ .uri = uri, .name = name };
}

/// Validates that a URI is a valid root URI (file:// scheme).
pub fn isValidRootUri(uri: []const u8) bool {
    return std.mem.startsWith(u8, uri, "file://");
}

test "fileRoot" {
    const r = fileRoot("/home/user/project", "Project");
    try std.testing.expectEqualStrings("/home/user/project", r.uri);
    try std.testing.expectEqualStrings("Project", r.name.?);
}

test "fileRootAlloc" {
    var r = try fileRootAlloc(std.testing.allocator, "/home/user/project", "Project");
    defer deinitAllocatedRoot(std.testing.allocator, &r);
    try std.testing.expect(std.mem.startsWith(u8, r.uri, "file://"));
    try std.testing.expectEqualStrings("Project", r.name.?);
}

test "root" {
    const r = root("file:///tmp", "Temp");
    try std.testing.expectEqualStrings("file:///tmp", r.uri);
    try std.testing.expectEqualStrings("Temp", r.name.?);
}

test "isValidRootUri" {
    try std.testing.expect(isValidRootUri("file:///home/user"));
    try std.testing.expect(!isValidRootUri("http://example.com"));
    try std.testing.expect(!isValidRootUri(""));
}
