---
title: "Architecture"
description: "Understand the MCP architecture including clients, servers, transports, and how components communicate via JSON-RPC."
keywords: [MCP architecture, clients, servers, transports, JSON-RPC, protocol layers]
---

# Architecture Overview

This overview of the Model Context Protocol (MCP) discusses its scope and core concepts, and provides an example demonstrating each core concept.

## Scope

The Model Context Protocol includes the following projects:

- **MCP Specification**: A specification of MCP that outlines the implementation requirements for clients and servers.
- **MCP SDKs**: SDKs for different programming languages that implement MCP.
- **MCP Development Tools**: Tools for developing MCP servers and clients, including the MCP Inspector.
- **MCP Reference Server Implementations**: Reference implementations of MCP servers.

MCP focuses solely on the protocol for context exchange—it does not dictate how AI applications use LLMs or manage the provided context.

## Architecture Diagram

```
+-----------------------+                   +-----------------------+
|       MCP Host        |                   |      MCP Server       |
| (e.g., Claude Desktop)|                   | (Tools, Data, Prompts)|
|                       |                   |                       |
|   +---------------+   |                   |   +---------------+   |
|   |  MCP Client   |   |   JSON-RPC 2.0    |   | Implementation|   |
|   |   (mcp.zig)   |<--+-------------------+-->|   (mcp.zig)   |   |
|   +---------------+   |   via Transport   |   +-------+-------+   |
+-----------------------+   (Stdio/HTTP)    +-----------------------+
                                                    |
                                            +-------v-------+
                                            | Capabilities  |
                                            | - Tools       |
                                            | - Resources   |
                                            | - Prompts     |
                                            +---------------+
```

## Concepts of MCP

### Participants

MCP follows a client-server architecture where an **MCP host** — an AI application like Claude Code or Claude Desktop — establishes connections to one or more **MCP servers**. The MCP host accomplishes this by creating one **MCP client** for each MCP server. Each MCP client maintains a dedicated one-to-one connection with its corresponding MCP server.

The key participants in the MCP architecture are:

- **MCP Host**: The AI application that coordinates and manages one or multiple MCP clients.
- **MCP Client**: A component that maintains a connection to an MCP server and obtains context from an MCP server for the MCP host to use.
- **MCP Server**: A program that provides context to MCP clients.

Note that _MCP server_ refers to the program that serves context data, regardless of where it runs. MCP servers can execute locally or remotely.

### Layers

MCP consists of two layers:

1.  **Data layer**: Defines the JSON-RPC based protocol for client-server communication, including lifecycle management, and core primitives, such as tools, resources, prompts and notifications.
2.  **Transport layer**: Defines the communication mechanisms and channels that enable data exchange between clients and servers, including transport-specific connection establishment, message framing, and authorization.

Conceptually the data layer is the inner layer, while the transport layer is the outer layer.

#### Data layer

The data layer implements a JSON-RPC 2.0 based exchange protocol that defines the message structure and semantics. This layer includes:

- **Lifecycle management**: Handles connection initialization, capability negotiation, and connection termination between clients and servers.
- **Server features**: Enables servers to provide core functionality including tools for AI actions, resources for context data, and prompts for interaction templates from and to the client.
- **Client features**: Enables servers to ask the client to sample from the host LLM, elicit input from the user, and log messages to the client.
- **Utility features**: Supports additional capabilities like notifications for real-time updates and progress tracking for long-running operations.

#### Transport layer

The transport layer manages communication channels and authentication between clients and servers. It handles connection establishment, message framing, and secure communication between MCP participants.

MCP supports two transport mechanisms:

- **Stdio transport**: Uses standard input/output streams for direct process communication between local processes on the same machine, providing optimal performance with no network overhead.
- **Streamable HTTP transport**: Uses HTTP POST for client-to-server messages with optional Server-Sent Events for streaming capabilities. This transport enables remote server communication and supports standard HTTP authentication methods including bearer tokens, API keys, and custom headers. MCP recommends using OAuth to obtain authentication tokens.

The transport layer abstracts communication details from the protocol layer, enabling the same JSON-RPC 2.0 message format across all transport mechanisms.
