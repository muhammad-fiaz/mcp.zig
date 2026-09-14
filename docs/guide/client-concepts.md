---
title: "Client Concepts"
description: "Core MCP client concepts: connecting to servers, discovery, and invoking tools, resources, and prompts."
keywords: [MCP client, elicitation, roots, sampling, client features, server connection]
---

# Understanding MCP Clients

MCP clients are instantiated by host applications to communicate with MCP servers. Each client handles one direct communication with one server.

## Core Client Features

In addition to using context from servers, clients provide features _to_ servers to enable richer interactions.

| Feature         | Explanation                                                              | Example                                          |
| :-------------- | :----------------------------------------------------------------------- | :----------------------------------------------- |
| **Elicitation** | Enables servers to request information from users during interactions.   | Asking for a missing booking detail.             |
| **Roots**       | Allows clients to specify filesystem boundaries/directories of interest. | "Travel Planning Workspace" folder.              |
| **Sampling**    | Allows servers to request LLM completions through the client (Agentic).  | A server asking the LLM to pick the best flight. |

### Elicitation

Elicitation allows servers to pause operations and ask the user for input (e.g., via a UI form).

- **Protocol**: `elicitation/requestInput`
- **Flow**: Server requests -> Client shows UI -> User inputs -> Client returns execution.

### Roots

Roots communicate filesystem access boundaries.

- **Protocol**: `roots/list`
- Roots are advisory boundaries (folders) telling the server where to focus.

### Sampling

Sampling enables servers to perform AI tasks using the Host's LLM connection.

- **Protocol**: `sampling/createMessage`
- **Control**: Puts the client/user in control of permissions, costs, and model selection.
- **Human-in-the-loop**: Users can review sampling requests.
