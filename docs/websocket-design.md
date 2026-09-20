# WebSocket for the Kyte web framework (design)

Status: proposed. Scope: a first-party RFC 6455 **server** in the stdlib web layer.

## Goal and non-goals

**Goal.** Let a Kyte web app serve a bidirectional, low-latency channel (collaborative editing,
terminals, presence, chat, games) that Server-Sent Events cannot, because SSE is server to client
only.

**Non-goals (v1).** No client-side WebSocket. No `permessage-deflate`. No subprotocol framework
(single optional negotiated subprotocol only). No standalone realtime library: this is one module.

**Positioning.** SSE plus datastar stays the default for hypermedia server-push. WebSocket is the
exception you reach for when you genuinely need the client to talk back in real time. The docs must
say this so it does not become the new reflex.

## Why it fits cheaply

The hard parts already exist, so this is a module, not a subsystem:

- **Connection takeover is proven.** `web/sse.ky` already takes over the socket after the finite
  request path and writes frames incrementally over the raw stream. A WebSocket upgrade is the same
  move: reply `101`, then own the socket. `web/app.ky` already treats `upgrade` as hop-by-hop.
- **The I/O loop is ready.** `net/eventedio.ky`'s `ReactorStream` gives `recvInto` / `sendBuf` /
  `recvIntoDeadline` / `isOpen` / `close`, all async on the reactor. A frame read/write loop is
  exactly that.
- **Handshake crypto is present.** `crypto/hash/sha1.ky` and `crypto/base64.ky`. Frame masking is a
  4-byte XOR.

## The seam (mirror SseHandler)

`web/sse.ky` exposes `SseHandler`, registered with `App.sse(path, handler)`. WebSocket mirrors it:

```kyte
// web/websocket.ky
pub trait WsHandler {
    // Called once per accepted connection AFTER a successful handshake. The handler
    // owns the receive loop and returns when the connection should close.
    async fn serve(self: WsHandler, ws: WebSocket, ctx: Context): void;
}
```

Registered the same way, so routing and DI are unchanged:

```kyte
app.ws("/echo", EchoHandler());
```

`Context` still carries the handshake request, so a handler reads cookies / session for auth exactly
like a normal route (`ctx.bind<T>()`, request headers) BEFORE the loop starts.

## The `WebSocket` object

A thin class over one `ReactorStream`. Text is validated UTF-8; binary is a raw buffer.

```kyte
pub class WebSocket {
    // Returns the next application message, or `undefined` once the peer closes.
    // Control frames (ping/pong/close) are handled internally and never surface here.
    pub async fn recv(self: WebSocket): Message | undefined;

    pub async fn sendText(self: WebSocket, s: string): int;      // bytes written, -1 on error
    pub async fn sendBinary(self: WebSocket, buf: long, len: int): int;

    pub async fn close(self: WebSocket, code: int, reason: string): void;  // sends Close, drains
    pub fn isOpen(self: WebSocket): bool;
}

pub struct Message { pub isText: bool, pub text: string, pub bytes: long, pub len: int }
```

A typical handler is a plain loop:

```kyte
class EchoHandler impl WsHandler {
    pub async fn serve(self: EchoHandler, ws: WebSocket, ctx: Context): void {
        while (true) {
            let m = await ws.recv();
            if (m == undefined) { break; }        // peer closed
            let _ = await ws.sendText(m.text);
        }
    }
}
```

## Handshake

On the upgrade request the framework verifies, then completes the handshake, then calls the handler:

1. `Upgrade: websocket` and `Connection: Upgrade` present; method `GET`; `Sec-WebSocket-Version: 13`.
2. **Origin check** against a configured allowlist (default: same-origin). This is the CSRF equivalent
   for WebSocket, since cookie-based CSRF tokens do not apply.
3. Optional subprotocol: if the app configured one and the client offered it, echo it in
   `Sec-WebSocket-Protocol`; else omit.
4. Compute `Sec-WebSocket-Accept = base64(sha1(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))` and
   reply `101 Switching Protocols`.

Any failure returns a normal HTTP error response on the same path (no takeover).

## Frame layer (RFC 6455)

Runs over `ReactorStream` after takeover:

- **Parse** the 2-byte header, extended length (7 / 7+16 / 7+64), and the mask. Client to server
  frames MUST be masked; reject unmasked with Close `1002`. Unmask with the 4-byte XOR key.
- **Opcodes:** `text (0x1)`, `binary (0x2)`, `close (0x8)`, `ping (0x9)`, `pong (0xA)`, continuation
  `(0x0)`. Reserved opcodes and RSV bits set (no extensions) close with `1002`.
- **Fragmentation:** reassemble `text`/`binary` + `continuation` up to a configured message cap, then
  surface one `Message`. Control frames may interleave and must not be fragmented.
- **Control frames handled internally:** reply to `ping` with `pong`; a received `pong` resets the
  idle timer; a received `close` triggers the close handshake and ends `recv()` with `undefined`.
- **Emit** unmasked server frames; fragment outbound only if larger than the write chunk.

## Keepalive, timeouts, backpressure

- The framework sends a `ping` every `idleMs` (default 30s) using `recvIntoDeadline`; two missed
  pongs close the connection with `1001`.
- Backpressure is inherited from the reactor: `sendBuf` suspends the coroutine until the socket is
  writable, so a slow client cannot make the server buffer unboundedly. A bounded outbound queue with
  a drop-oldest or close policy is a v1.1 option, not v1.
- Hard caps (configurable): max frame size, max reassembled message size, max concurrent connections
  per instance. Exceeding a size cap closes with `1009`.

## Security

- Origin allowlist (above).
- Auth is done on the handshake request, before takeover, reusing the app's session/cookie auth.
- Text frames are UTF-8 validated; invalid UTF-8 closes with `1007`.
- Size caps bound memory per connection.

## Deployment

Same shape as the existing SSE note. A WebSocket is long-lived and holds one reactor slot for its
lifetime, and the web model is single-reactor, so scaling is instances behind `proxyd`. `proxyd` must
pass `Upgrade` / `Connection: Upgrade` through and route stickily (a connection stays pinned to the
instance that accepted it). Document the per-instance connection cap.

## Testing and the gate

A conformance case (`cases/NNN_websocket_echo.ky`) that, in one process, starts an app with `/echo`
and `/chat`, connects a Kyte-side raw client over a loopback socket, and asserts:

- handshake accept value is correct; a bad Origin is rejected with an HTTP error;
- text and binary echo round-trip, including a fragmented message;
- ping is answered with pong; an unmasked client frame is rejected with `1002`;
- a clean close handshake ends `recv()` with `undefined` and frees the connection (ASAN clean).

A later, optional job can run an Autobahn-lite subset for spec breadth.

## Milestones

1. Handshake + framing + echo handler + the echo conformance case (the vertical slice).
2. Fragmentation, ping/pong keepalive, close handshake, size caps.
3. Origin/auth wiring + a small chat example (`web/websocket` + datastar or plain JS client).
4. Docs: a WebSocket section in the guide that leads with "SSE is still the default".
