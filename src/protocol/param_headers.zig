//! `x-mcp-header` support.
//!
//! A server may annotate specific tool parameters with an `x-mcp-header`
//! property in its `inputSchema`. Conforming Streamable HTTP clients mirror
//! those designated values into `Mcp-Param-{Name}` headers so intermediaries
//! can route without parsing the body.
//!
//! Only annotations reachable through a chain of `properties` keys are valid,
//! and only `string`, `integer` and `boolean` parameters may be annotated. A
//! `number` parameter is explicitly not allowed, nor is an annotation hidden
//! behind `items`, a composition keyword, a conditional, or `$ref`.

const std = @import("std");
const httpx = @import("httpx");
const protocol = @import("protocol.zig");

/// Largest integer a JavaScript client can represent exactly.
pub const max_safe_integer: i64 = 9007199254740991;

pub const Error = std.mem.Allocator.Error || error{
    /// The annotation value was empty.
    EmptyName,
    /// The annotation value was not an HTTP field-name token.
    InvalidName,
    /// Two annotations differed only by case.
    DuplicateName,
    /// The annotated parameter was not a string, integer, or boolean.
    UnsupportedType,
    /// An integer argument exceeded the JavaScript safe range.
    IntegerOutOfRange,
    /// An `x-mcp-header` existed somewhere the schema could not reach.
    UnreachableAnnotation,
};

/// One validated `x-mcp-header` annotation.
pub const Annotation = struct {
    /// Chain of `properties` keys leading from the schema root to the value.
    /// The slice is borrowed from the parsed schema; the outer slice is owned.
    path: []const []const u8,
    /// The `{Name}` portion of the emitted `Mcp-Param-{Name}` header.
    name: []const u8,
    kind: Kind,

    pub const Kind = enum { string, integer, boolean };

    /// Releases the annotation list returned by `collect`.
    pub fn freeList(allocator: std.mem.Allocator, list: []Annotation) void {
        freePaths(allocator, list);
        allocator.free(list);
    }

    /// Releases only the per-annotation paths, leaving the outer slice alone.
    pub fn freePaths(allocator: std.mem.Allocator, list: []const Annotation) void {
        for (list) |a| allocator.free(a.path);
    }
};

/// Checks a single annotation value against the field-name constraints.
fn validateName(value: std.json.Value) Error![]const u8 {
    const name = switch (value) {
        .string => |s| s,
        else => return error.InvalidName,
    };
    if (name.len == 0) return error.EmptyName;
    for (name) |c| {
        // httpx already implements the RFC field-name token character class,
        // so reuse it rather than keeping a second copy.
        if (!httpx.parse.isTokenChar(c)) return error.InvalidName;
    }
    return name;
}

/// Reads and validates the annotation on a single parameter schema.
fn annotationOf(schema: std.json.Value) Error!?Annotation {
    if (schema != .object) return null;
    const raw = schema.object.get("x-mcp-header") orelse return null;

    const name = try validateName(raw);

    const type_value = schema.object.get("type") orelse return error.UnsupportedType;
    const type_name = switch (type_value) {
        .string => |s| s,
        else => return error.UnsupportedType,
    };
    const kind: Annotation.Kind = if (std.mem.eql(u8, type_name, "string"))
        .string
    else if (std.mem.eql(u8, type_name, "integer"))
        .integer
    else if (std.mem.eql(u8, type_name, "boolean"))
        .boolean
    else
        return error.UnsupportedType;

    return Annotation{ .path = &.{}, .name = name, .kind = kind };
}

/// Walks the statically reachable part of a schema, following only `properties`.
fn walk(
    allocator: std.mem.Allocator,
    node: std.json.Value,
    path: []const []const u8,
    out: *std.ArrayList(Annotation),
) Error!void {
    if (node != .object) return;
    const props = node.object.get("properties") orelse return;
    if (props != .object) return;

    var it = props.object.iterator();
    while (it.next()) |entry| {
        const sub = entry.value_ptr.*;

        const extended = try allocator.alloc([]const u8, path.len + 1);
        @memcpy(extended[0..path.len], path);
        extended[path.len] = entry.key_ptr.*;

        // Once the slice is stored in an annotation it is owned by the result
        // and must not be released here.
        var owned_by_result = false;
        defer if (!owned_by_result) allocator.free(extended);

        if (try annotationOf(sub)) |ann| {
            var stored = ann;
            stored.path = extended;
            try out.append(allocator, stored);
            owned_by_result = true;
        }

        // The recursion only borrows the keys, which belong to the parsed
        // schema, so it is safe to pass `extended` down.
        try walk(allocator, sub, extended, out);
    }
}

/// Counts every `x-mcp-header` key anywhere in a value, reachable or not.
fn countAnnotations(node: std.json.Value) usize {
    var total: usize = 0;
    switch (node) {
        .object => |o| {
            var it = o.iterator();
            while (it.next()) |entry| {
                if (std.mem.eql(u8, entry.key_ptr.*, "x-mcp-header")) total += 1;
                total += countAnnotations(entry.value_ptr.*);
            }
        },
        .array => |arr| {
            for (arr.items) |item| total += countAnnotations(item);
        },
        else => {},
    }
    return total;
}

/// Orders annotations by property path.
///
/// JSON objects have no defined iteration order, so sorting keeps both the
/// emitted headers and any rejection reason stable across runs.
fn pathLessThan(_: void, a: Annotation, b: Annotation) bool {
    const n = @min(a.path.len, b.path.len);
    for (a.path[0..n], b.path[0..n]) |x, y| {
        const order = std.mem.order(u8, x, y);
        if (order != .eq) return order == .lt;
    }
    return a.path.len < b.path.len;
}

/// Collects the valid annotations of a tool's `inputSchema`.
///
/// Returns every reachable annotation, or an error describing why the tool
/// definition is non-conforming. Callers should exclude a tool whose
/// `tools/list` entry reports an error here.
pub fn collect(allocator: std.mem.Allocator, input_schema: std.json.Value) Error![]Annotation {
    var out: std.ArrayList(Annotation) = .empty;
    errdefer {
        // The ArrayList still owns `out.items`, so only the paths go here.
        Annotation.freePaths(allocator, out.items);
        out.deinit(allocator);
    }

    try walk(allocator, input_schema, &.{}, &out);
    std.mem.sort(Annotation, out.items, {}, pathLessThan);

    // An annotation the walk could not reach makes the definition invalid.
    if (countAnnotations(input_schema) != out.items.len) return error.UnreachableAnnotation;

    // Header names must be unique ignoring case.
    for (out.items, 0..) |a, i| {
        for (out.items[i + 1 ..]) |b| {
            if (std.ascii.eqlIgnoreCase(a.name, b.name)) return error.DuplicateName;
        }
    }

    return out.toOwnedSlice(allocator);
}

/// Resolves an argument value at an annotation's property path.
pub fn valueAtPath(arguments: std.json.Value, path: []const []const u8) ?std.json.Value {
    var current = arguments;
    for (path) |key| {
        if (current != .object) return null;
        const next = current.object.get(key) orelse return null;
        current = next;
    }
    return current;
}

/// Mirrors annotated argument values into `Mcp-Param-{Name}` headers.
///
/// A `null` or absent value omits its header, per the spec. Each appended
/// header name and value is owned by the caller.
pub fn appendHeaders(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(httpx.Header),
    annotations: []const Annotation,
    arguments: std.json.Value,
) (Error || std.mem.Allocator.Error)!void {
    for (annotations) |ann| {
        const value = valueAtPath(arguments, ann.path) orelse continue;
        if (value == .null) continue;

        const raw: []const u8 = switch (value) {
            .string => |s| s,
            .bool => |b| if (b) "true" else "false",
            .integer => |i| blk: {
                if (i > max_safe_integer or i < -max_safe_integer) return error.IntegerOutOfRange;
                break :blk try std.fmt.allocPrint(allocator, "{d}", .{i});
            },
            else => return error.UnsupportedType,
        };
        // Ownership of a formatted integer transfers to the header below; a
        // borrowed string does not need freeing.
        var owned_raw: ?[]const u8 = null;
        defer if (owned_raw) |r| allocator.free(r);
        if (value == .integer) owned_raw = raw;

        // A plain-ASCII value that looks like the sentinel must also be
        // encoded, so the two encodings stay unambiguous.
        const encoded = try protocol.encodeHeaderValue(allocator, raw);
        const header_name = try std.fmt.allocPrint(
            allocator,
            protocol.HEADER_PARAM_PREFIX ++ "{s}",
            .{ann.name},
        );
        try out.append(allocator, .{ .name = header_name, .value = encoded });
    }
}

// tests

const testing = std.testing;

test "x-mcp-header: collects only annotated, reachable properties" {
    const schema = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"type":"object","properties":{
        \\  "region":{"type":"string","x-mcp-header":"Region"},
        \\  "limit":{"type":"integer","x-mcp-header":"Limit"},
        \\  "verbose":{"type":"boolean","x-mcp-header":"Verbose"},
        \\  "query":{"type":"string"},
        \\  "nested":{"type":"object","properties":{"id":{"type":"string","x-mcp-header":"Id"}}}
        \\}}
    , .{});
    defer schema.deinit();

    const list = try collect(testing.allocator, schema.value);
    defer Annotation.freeList(testing.allocator, list);

    try testing.expectEqual(@as(usize, 4), list.len);
    // Results are ordered by property path: limit, nested.id, region, verbose.
    try testing.expectEqualStrings("Limit", list[0].name);
    try testing.expectEqual(Annotation.Kind.integer, list[0].kind);
    try testing.expectEqualStrings("nested", list[1].path[0]);
    try testing.expectEqualStrings("id", list[1].path[1]);
    try testing.expectEqualStrings("Region", list[2].name);
    try testing.expectEqualStrings("Verbose", list[3].name);
}

test "x-mcp-header: rejects number, bad names, and duplicates" {
    const number_schema = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"type":"object","properties":{"n":{"type":"number","x-mcp-header":"N"}}}
    , .{});
    defer number_schema.deinit();
    try testing.expectError(error.UnsupportedType, collect(testing.allocator, number_schema.value));

    const empty = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"type":"object","properties":{"n":{"type":"string","x-mcp-header":""}}}
    , .{});
    defer empty.deinit();
    try testing.expectError(error.EmptyName, collect(testing.allocator, empty.value));

    const crlf = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"type":"object","properties":{"n":{"type":"string","x-mcp-header":"Bad\rName"}}}
    , .{});
    defer crlf.deinit();
    try testing.expectError(error.InvalidName, collect(testing.allocator, crlf.value));

    const dupe = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"type":"object","properties":{
        \\  "a":{"type":"string","x-mcp-header":"Region"},
        \\  "b":{"type":"string","x-mcp-header":"region"}}}
    , .{});
    defer dupe.deinit();
    try testing.expectError(error.DuplicateName, collect(testing.allocator, dupe.value));
}

test "x-mcp-header: rejects annotations hidden behind items" {
    const schema = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"type":"object","properties":{
        \\  "rows":{"type":"array","items":{"type":"object","properties":{
        \\    "id":{"type":"string","x-mcp-header":"Id"}}}}}}
    , .{});
    defer schema.deinit();
    try testing.expectError(error.UnreachableAnnotation, collect(testing.allocator, schema.value));
}

test "x-mcp-header: extracts by path, omits absent and null" {
    const schema = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"type":"object","properties":{
        \\  "region":{"type":"string","x-mcp-header":"Region"},
        \\  "limit":{"type":"integer","x-mcp-header":"Limit"},
        \\  "opt":{"type":"string","x-mcp-header":"Opt"}}}
    , .{});
    defer schema.deinit();
    const list = try collect(testing.allocator, schema.value);
    defer Annotation.freeList(testing.allocator, list);

    const args = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"region":"us-west1","limit":42,"opt":null}
    , .{});
    defer args.deinit();

    var headers: std.ArrayList(httpx.Header) = .empty;
    defer {
        for (headers.items) |h| {
            testing.allocator.free(h.name);
            testing.allocator.free(h.value);
        }
        headers.deinit(testing.allocator);
    }
    try appendHeaders(testing.allocator, &headers, list, args.value);
    try testing.expectEqual(@as(usize, 2), headers.items.len);
    // Headers follow path order, so the integer sorts before the string.
    try testing.expectEqualStrings("Mcp-Param-Limit", headers.items[0].name);
    try testing.expectEqualStrings("42", headers.items[0].value);
    try testing.expectEqualStrings("Mcp-Param-Region", headers.items[1].name);
    try testing.expectEqualStrings("us-west1", headers.items[1].value);
}

test "x-mcp-header: enforces the JavaScript safe integer range" {
    const schema = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"type":"object","properties":{"n":{"type":"integer","x-mcp-header":"N"}}}
    , .{});
    defer schema.deinit();
    const list = try collect(testing.allocator, schema.value);
    defer Annotation.freeList(testing.allocator, list);

    const args = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"n":9007199254740993}
    , .{});
    defer args.deinit();

    var headers: std.ArrayList(httpx.Header) = .empty;
    defer headers.deinit(testing.allocator);
    try testing.expectError(
        error.IntegerOutOfRange,
        appendHeaders(testing.allocator, &headers, list, args.value),
    );
}

test "x-mcp-header: annotation names reuse the httpx token rules" {
    // The same RFC field-name token class httpx validates is used here, so a
    // value httpx would accept as a header name is accepted as an annotation.
    try testing.expect(httpx.parse.isTokenChar('R'));
    try testing.expect(!httpx.parse.isTokenChar(' '));
    try testing.expect(!httpx.parse.isTokenChar('\n'));
}
