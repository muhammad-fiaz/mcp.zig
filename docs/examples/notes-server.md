# Notes Server

A stateful MCP server that stores text notes in memory. This example demonstrates the most
important pattern for building stateful servers in mcp.zig: passing a **context struct**
via `user_data` to share mutable state across all tool handlers.

**Source:** [`examples/notes_server.zig`](https://github.com/muhammad-fiaz/mcp.zig/blob/main/examples/notes_server.zig)

## Run

```bash
zig build run-notes
# or
./zig-out/bin/notes-server
```

## Features

| Feature | Description |
|---------|-------------|
| `create_note` tool | Create or overwrite a note by title |
| `read_note` tool | Read a note's body by title |
| `delete_note` tool | Delete a note by title |
| `list_notes` tool | List all note titles |
| `notes://index` resource | Dynamic resource listing all titles |
| Resource template | `notes://{title}` for individual notes |
| Notifications | `notifyResourcesChanged` on create/delete |

## Key Implementation Pattern: `user_data` Context

```zig
// Define a context struct to hold shared mutable state
const Ctx = struct {
    store: NoteStore,
    server: *mcp.Server,
    io: std.Io,
    alloc: std.mem.Allocator,
};

// Initialize context before the server
var ctx: Ctx = .{
    .store = NoteStore.init(allocator),
    .server = &server,
    .io = io,
    .alloc = allocator,
};

// Pass &ctx as user_data when registering tools
try server.addTool(.{
    .name = "create_note",
    .user_data = &ctx,
    .handler = createNoteHandler,
    // ...
});
```

Then in each handler, cast `user_data` back:

```zig
fn createNoteHandler(
    user_data: ?*anyopaque,
    io: std.Io,
    allocator: std.mem.Allocator,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    const ctx: *Ctx = @ptrCast(@alignCast(user_data.?));
    // ... use ctx.store ...
}
```

## List-Change Notifications

When a note is created or deleted, the server notifies connected clients that the resource
list has changed:

```zig
ctx.server.notifyResourcesChanged(io, allocator) catch {};
```

This triggers `notifications/resources/list_changed` on all subscribed clients,
causing them to refresh their resource list.

## Tools Schema

All tools use `InputSchemaBuilder`:

```zig
fn buildCreateSchema(allocator: std.mem.Allocator) !mcp.types.InputSchema {
    var b = mcp.schema.InputSchemaBuilder.init(allocator);
    defer b.deinit(allocator);
    _ = b.setSchemaDialect("https://json-schema.org/draft/2020-12/schema");
    _ = try b.addString(allocator, "title", "Unique note title", true);
    _ = try b.addString(allocator, "body", "Note content (plain text)", true);
    return b.toInputSchema(allocator);
}
```

## Claude Desktop Configuration

```json
{
  "mcpServers": {
    "notes": {
      "command": "/path/to/zig-out/bin/notes-server"
    }
  }
}
```

Notes are in-memory and will be reset on restart.
