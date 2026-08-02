# IPC protocol

Noren uses framed messages over a Unix domain socket. Zig struct layout is
never part of the wire format.

Every frame begins with this fixed 20-byte, big-endian header:

| Field | Bytes | Meaning |
| --- | ---: | --- |
| magic | 4 | ASCII `NRN1` |
| major | 2 | incompatible protocol generation |
| minor | 2 | capability-negotiated revision |
| kind | 2 | message kind |
| flags | 2 | kind-specific flags |
| request_id | 4 | request/response correlation |
| payload_len | 4 | payload bytes following the header |

Payloads are capped at 16 MiB. The parser accepts split headers, split payloads
and multiple frames delivered in one read. It validates magic and length before
allocating a payload. Control messages use validated UTF-8 JSON; raw input
and render messages remain byte payloads.

Protocol version in Noren 0.4.3 remains `1.0`. M4 adds structured
`command_request` messages for Pane, Workspace, camera, Session rename and
ephemeral prefix-menu presentation state to the M2 `hello`/`welcome`,
`attach_request`/`attached`, resize, input, render, detach and ping/pong
messages over an owner-only Unix socket.

Mouse clicks use the existing `input_event` message kind with a validated JSON
payload containing zero-based outer-terminal `x`/`y`, button, pressed state and
Shift/Alt/Ctrl modifiers. The Server performs layout hit-testing and never
trusts a client-supplied Pane index. Border clicks focus a Pane only; content
clicks are translated to the Pane's terminal coordinates and passed through
libvterm so the child receives bytes only after enabling mouse reporting.
