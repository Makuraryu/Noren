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
allocating a payload. Control messages will use validated UTF-8 JSON; raw input
and render messages remain byte payloads.

Protocol version in Noren 0.1.0 is `1.0`. The current M0 milestone implements
the framing library and tests but does not open a socket.
