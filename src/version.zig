/// Current version of the MCP library
pub const version = "0.0.9";

test "library version is 0.0.9" {
    const std = @import("std");
    try std.testing.expectEqualStrings("0.0.9", version);
}
