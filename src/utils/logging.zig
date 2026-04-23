//! MCP Logging Module
//!
//! Provides structured logging for MCP servers with syslog-compatible
//! severity levels. Supports both instance-based and global loggers.

const std = @import("std");

/// Log severity levels following syslog conventions.
pub const Level = enum(u8) {
    debug = 7,
    info = 6,
    notice = 5,
    warning = 4,
    @"error" = 3,
    critical = 2,
    alert = 1,
    emergency = 0,

    /// Returns the string representation of this log level.
    pub fn toString(self: Level) []const u8 {
        return @tagName(self);
    }

    /// Parses a log level from its string representation.
    pub fn fromString(str: []const u8) ?Level {
        inline for (std.meta.fields(Level)) |f| {
            if (std.mem.eql(u8, f.name, str)) return @enumFromInt(f.value);
        }
        return null;
    }
};

/// Configuration for a logger instance.
pub const Config = struct {
    level: Level = .info,
    name: ?[]const u8 = null,
    stderr: bool = true,
};

/// Logger instance for structured log output.
pub const Logger = struct {
    config: Config,

    /// Creates a new logger with the given configuration.
    pub fn init(config: Config) Logger {
        return .{ .config = config };
    }

    /// Logs a debug-level message.
    pub fn debug(self: *Logger, message: []const u8) void {
        self.log(.debug, message);
    }

    /// Logs an info-level message.
    pub fn info(self: *Logger, message: []const u8) void {
        self.log(.info, message);
    }

    /// Logs a warning-level message.
    pub fn warning(self: *Logger, message: []const u8) void {
        self.log(.warning, message);
    }

    /// Logs an error-level message.
    pub fn err(self: *Logger, message: []const u8) void {
        self.log(.@"error", message);
    }

    /// Logs a message at the specified level.
    pub fn log(self: *Logger, level: Level, message: []const u8) void {
        if (@intFromEnum(level) > @intFromEnum(self.config.level)) return;

        if (self.config.stderr) {
            std.debug.print("[{s}] {s}\n", .{ level.toString(), message });
        }
    }
};

var global_logger: ?Logger = null;

/// Initializes the global logger with the given configuration.
pub fn initGlobal(config: Config) void {
    global_logger = Logger.init(config);
}

/// Logs a debug message to the global logger.
pub fn debug(message: []const u8) void {
    if (global_logger) |*l| l.debug(message);
}

/// Logs an info message to the global logger.
pub fn info(message: []const u8) void {
    if (global_logger) |*l| l.info(message);
}

/// Logs a warning message to the global logger.
pub fn warning(message: []const u8) void {
    if (global_logger) |*l| l.warning(message);
}

/// Logs an error message to the global logger.
pub fn err(message: []const u8) void {
    if (global_logger) |*l| l.err(message);
}

test "Level conversion" {
    try std.testing.expectEqualStrings("debug", Level.debug.toString());
    try std.testing.expectEqual(Level.info, Level.fromString("info").?);
}
