/// Current version of the MCP library
pub const version = "0.0.8";

test "library version is 0.0.8" {
    const std = @import("std");
    try std.testing.expectEqualStrings("0.0.8", version);
}
