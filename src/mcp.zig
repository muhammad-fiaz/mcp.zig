//! MCP.zig - Model Context Protocol Library for Zig
//!
//! A native Zig implementation of the Model Context Protocol (MCP), an open standard
//! by Anthropic for connecting AI applications to external systems.
//!
//! This library provides both server and client implementations, enabling Zig developers
//! to build MCP-compatible tools, resources, and prompts that integrate with AI applications.
//!
//! Supports MCP protocol version 2026-07-28 with:
//! - Stateless per-request model (no initialize/initialized handshake)
//! - server/discover as the mandatory entry point
//! - MRTR (Multi Round-Trip Requests) via InputRequiredResult
//! - subscriptions/listen for resource subscriptions
//! - HTTP transport via httpx.zig
//!
//! ## Example
//!
//! ```zig
//! const mcp = @import("mcp");
//!
//! pub fn main() !void {
//!     var server = mcp.Server.init(.{
//!         .name = "my-server",
//!         .version = "1.0.0",
//!     });
//!     try server.addTool(.{
//!         .name = "greet",
//!         .description = "Greet a user",
//!         .handler = greetHandler,
//!     });
//!     try server.run(.stdio);
//! }
//! ```

const std = @import("std");

/// Report and version utilities
pub const report = @import("report.zig");
pub const version_info = @import("version.zig");

/// URL for reporting bugs and issues with the MCP library.
pub const ISSUES_URL = report.ISSUES_URL;

/// Library version information.
pub const VERSION = version_info.version;

/// Prints an error message with instructions for reporting bugs.
pub fn reportError(err: anyerror) void {
    report.reportError(err);
}

/// Prints a custom error message with instructions for reporting bugs.
pub fn reportErrorMessage(message: []const u8) void {
    report.reportErrorMessage(message);
}

// Protocol types and JSON-RPC implementation
pub const protocol = @import("protocol/protocol.zig");
pub const types = @import("protocol/types.zig");
pub const jsonrpc = @import("protocol/jsonrpc.zig");
pub const schema = @import("protocol/schema.zig");

// Transport layer implementations
pub const transport = @import("transport/transport.zig");
pub const StdioTransport = transport.StdioTransport;
pub const HttpTransport = transport.HttpTransport;
pub const Transport = transport.Transport;

// Server-side components
pub const server = @import("server/server.zig");
pub const Server = server.Server;
pub const ServerConfig = server.ServerConfig;

pub const tools = @import("server/tools.zig");
pub const Tool = tools.Tool;
pub const ToolBuilder = tools.ToolBuilder;
pub const ToolResult = tools.ToolResult;

pub const resources = @import("server/resources.zig");
pub const Resource = resources.Resource;
pub const ResourceTemplate = resources.ResourceTemplate;

pub const prompts = @import("server/prompts.zig");
pub const Prompt = prompts.Prompt;
pub const PromptMessage = prompts.PromptMessage;

// Client-side components
pub const client = @import("client/client.zig");
pub const Client = client.Client;
pub const ClientConfig = client.ClientConfig;
pub const elicitation = @import("client/elicitation.zig");
pub const roots = @import("client/roots.zig");
pub const sampling = @import("client/sampling.zig");

// MRTR types (2026-07-28)
pub const InputRequest = @import("protocol/types.zig").InputRequest;
pub const InputResponse = @import("protocol/types.zig").InputResponse;
pub const ResultType = @import("protocol/types.zig").ResultType;
pub const SubscriptionFilter = @import("protocol/types.zig").SubscriptionFilter;
pub const CacheScope = @import("protocol/types.zig").CacheScope;

// Protocol types
pub const DiscoverResult = @import("protocol/protocol.zig").DiscoverResult;

// Utilities
pub const utils = @import("utils/mod.zig");
pub const errors = @import("utils/errors.zig");
pub const logging = @import("utils/logging.zig");
pub const progress = @import("utils/progress.zig");
pub const middleware = @import("utils/middleware.zig");

// Convenience re-exports for middleware
pub const RateLimiter = middleware.RateLimiter;
pub const RequestValidator = middleware.RequestValidator;
pub const BatchRequest = middleware.BatchRequest;
pub const LoggingContext = middleware.LoggingContext;

test {
    std.testing.refAllDecls(@This());
}
