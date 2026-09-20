#!/usr/bin/env bash
# End-to-end WebSocket check: builds a one-route echo app, runs it, and drives it with a
# raw-socket client (handshake + masked frames) to verify the full RFC 6455 path. This lives
# outside the `kyte test` corpus because the server owns the reactor for its lifetime, so a
# client and server cannot share one `kyte test` process. See docs/websocket-design.md.
#
# Usage:  KYTE=~/.kyte/bin/kyte ./conformance/integration/websocket_echo.sh
set -euo pipefail

KYTE="${KYTE:-$HOME/.kyte/bin/kyte}"
PORT="${WS_PORT:-8092}"
WORK="$(mktemp -d)"
trap 'kill "${SRV:-0}" 2>/dev/null || true; lsof -ti tcp:$PORT 2>/dev/null | xargs kill -9 2>/dev/null || true; rm -rf "$WORK"' EXIT

cat > "$WORK/app.ky" <<'KY'
import web.app;
import web.websocket;
import web.request;

class Echo impl WsHandler {
    pub async fn serve(self: Echo, ws: websocket.WebSocket, req: request.Request): void {
        while (ws.isOpen()) {
            let m = await ws.recv();
            if (m == undefined) { break; }
            if (m.isText) { let _ = await ws.sendText(m.text); }
            else { let _ = await ws.sendBinary(m.data, m.len); }
        }
    }
}

fn main(): int {
    let a = app.App();
    a.ws("/echo", Echo());
    a.run(WS_PORT_PLACEHOLDER);
    return 0;
}
KY
sed -i.bak "s/WS_PORT_PLACEHOLDER/$PORT/" "$WORK/app.ky"

"$KYTE" build --file "$WORK/app.ky" -o "$WORK/app.out" >/dev/null
codesign -s - -f "$WORK/app.out" 2>/dev/null || true
lsof -ti tcp:$PORT 2>/dev/null | xargs kill -9 2>/dev/null || true
"$WORK/app.out" >"$WORK/server.log" 2>&1 &
SRV=$!
sleep 1

WS_PORT=$PORT python3 - <<'PY'
import socket, base64, os, sys
PORT = int(os.environ["WS_PORT"])
def connect():
    s = socket.create_connection(("127.0.0.1", PORT), timeout=5)
    key = base64.b64encode(os.urandom(16)).decode()
    s.sendall((f"GET /echo HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
               f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
    r = s.recv(4096)
    assert b"101 Switching Protocols" in r and b"Sec-WebSocket-Accept" in r, "handshake failed"
    return s
def mask(p):
    m = os.urandom(4); return m + bytes(p[i] ^ m[i % 4] for i in range(len(p)))
def send(s, op, payload, fin=True):
    b0 = (0x80 if fin else 0) | op; n = len(payload)
    if n < 126: hdr = bytes([b0, 0x80 | n])
    elif n <= 0xFFFF: hdr = bytes([b0, 0x80 | 126, (n >> 8) & 0xff, n & 0xff])
    else: hdr = bytes([b0, 0x80 | 127]) + n.to_bytes(8, "big")
    s.sendall(hdr + mask(payload))
def recv(s):
    h = s.recv(2); op = h[0] & 0x0F; ln = h[1] & 0x7F
    if ln == 126: ln = int.from_bytes(s.recv(2), "big")
    elif ln == 127: ln = int.from_bytes(s.recv(8), "big")
    d = b""
    while len(d) < ln: d += s.recv(ln - len(d))
    return op, d

fail = 0
def check(name, cond):
    global fail
    print(("PASS " if cond else "FAIL ") + name)
    if not cond: fail += 1

s = connect(); send(s, 0x1, b"hello"); op, d = recv(s); check("text echo", op == 1 and d == b"hello"); s.close()
s = connect(); big = b"A" * 300; send(s, 0x1, big); op, d = recv(s); check("large (16-bit len)", op == 1 and d == big); s.close()
s = connect(); send(s, 0x2, b"\x00\x01\x02\xff"); op, d = recv(s); check("binary echo", op == 2 and d == b"\x00\x01\x02\xff"); s.close()
s = connect(); send(s, 0x9, b"py"); op, d = recv(s); check("ping->pong", op == 0xA and d == b"py"); s.close()
s = connect(); send(s, 0x1, b"he", fin=False); send(s, 0x0, b"llo", fin=True); op, d = recv(s); check("fragmented", op == 1 and d == b"hello"); s.close()
s = connect(); s.sendall(bytes([0x88, 0x80]) + os.urandom(4)); op, d = recv(s); check("close handshake", op == 0x8); s.close()
sys.exit(1 if fail else 0)
PY
rc=$?
if [ $rc -ne 0 ]; then echo "--- server log ---"; cat "$WORK/server.log"; fi
exit $rc
