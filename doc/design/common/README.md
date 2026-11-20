---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: documentation, index, common, design
scope: The design pages of the shared units in Http2.Common, which the client and the server use.
---

# Common design

This directory holds the design pages of the shared units. The client and the
server use these units through `Http2.Common`.

| Document | Subject |
| --- | --- |
| [Architecture](architecture.md) | Common, role, and provider boundaries. |
| [Body writer](body.md) | The shared body writer contract and its buffer. |
| [Format helpers](formats.md) | The text, JSON and XML helpers over the body reader and writer, and their errors and memory. |
| [Protocol](protocol.md) | The shared HTTP/2 protocol areas and their RFC references. |
| [URI](uri.md) | The shared URI parser, host rules, reference resolution and origin helpers. |
| [Header names and status codes](names.md) | The header-name constants and the status-code constants. |
| [Cookies](cookies.md) | The cookie record, the Set-Cookie and Cookie helpers, and the case-sensitive parameter map. |
| [Common TLS context](tls-context.md) | Shared context, policy, identity, and session contract. |
