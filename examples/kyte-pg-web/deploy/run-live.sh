#!/usr/bin/env bash
# Deploys the sandwich shop under the Kyte orchestrator and drives it end to end.
#
# orchd reads app.yaml (at the project root) and supervises N replicas in fd-handoff
# mode; the service gateway load-balances client connections across them by
# passing accepted sockets to the replicas over the rendezvous unix socket.
# fd-handoff is required so the long-lived SSE order-status stream is carried
# correctly (a buffering L7 proxy cannot). See DESIGN.md section 15.
#
# Prerequisites: PostgreSQL with the sandwichshop database (schema.sql + seed.sql),
# the shop built to ./build/shop, and the orchestrator built
# (cd packages/nova-orchestrator && ./build.sh). Run from the project root.
set -u
export PATH="$HOME/.kyte/bin:$PATH"

REPO=/Users/kamlesh/nova-lang
ORCHD="$REPO/packages/nova-orchestrator/build/debug/bin/orchd"
SVC="$REPO/packages/nova-orchestrator/build/debug/bin/service"
SOCK=/tmp/kyte-shop.sock          # rendezvous socket: /tmp/kyte-<manifest name>.sock
FRONT=8140                        # gateway front port
DSN="postgresql://kamlesh@127.0.0.1:5432/sandwichshop"

cleanup() {
    pkill -9 -x orchd 2>/dev/null
    pkill -9 -x service 2>/dev/null
    pkill -9 -f "build/shop" 2>/dev/null
    rm -f "$SOCK" /tmp/shop-discovery
}
trap cleanup EXIT
cleanup; sleep 0.5

[ -x "$ORCHD" ] || { echo "build the orchestrator: (cd packages/nova-orchestrator && ./build.sh)"; exit 1; }
[ -x ./build/shop ] || { echo "build the shop: kyte build --file src/main.ky -o build/shop"; exit 1; }

echo ">>> orchd: reconcile app.yaml (project root), supervise the shop replicas (fd-handoff)"
# No SHOP_DSN here: the app's config now lives in the manifest's `config:` block, which orchd injects
# into every replica as environment variables (DB_DSN, DB_POOL_SIZE, ...). The manifest is the single
# source of truth for both how the app runs and how it is configured.
"$ORCHD" deploy/orchd.json > /tmp/orchd.log 2>&1 &
sleep 3
echo "    replicas running: $(pgrep -f 'build/shop' | wc -l | tr -d ' ')"

echo ">>> service: gateway on :$FRONT, hands off client sockets to the replicas"
KYTE_HANDOFF_SOCK="$SOCK" KYTE_PORT="$FRONT" "$SVC" > /tmp/svc.log 2>&1 &
sleep 2
echo "    backends connected: $(grep -ic 'connected' /tmp/svc.log)"

echo ">>> smoke test through the gateway"
for i in 1 2 3 4; do
    curl -s -m 3 -o /dev/null -w "    /products req$i: HTTP %{http_code}\n" "http://127.0.0.1:$FRONT/products"
done

echo ">>> end-to-end: order + live status through the gateway"
JAR=/tmp/shop-runlive-jar; rm -f "$JAR"   # carry the cartid cookie across the flow
P=$(psql -d sandwichshop -tAc "SELECT id FROM products WHERE name='BLT';" 2>/dev/null)
curl -s -c "$JAR" -b "$JAR" -m3 -X POST "http://127.0.0.1:$FRONT/cart/add?product=$P" -H 'Content-Type: application/json' -d '{}' >/dev/null
curl -s -c "$JAR" -b "$JAR" -m3 -X POST "http://127.0.0.1:$FRONT/checkout" -H 'Content-Type: application/json' -d '{"delivery":"pickup"}' >/dev/null
OID=$(psql -d sandwichshop -tAc "SELECT id FROM orders ORDER BY created_at DESC LIMIT 1;" 2>/dev/null)
( curl -sN -m 4 "http://127.0.0.1:$FRONT/orders/$OID/events" > /tmp/shop_sse.txt 2>/dev/null ) &
sleep 1
curl -s -m3 -X POST "http://127.0.0.1:$FRONT/orders/advance?order=$OID" -H 'Content-Type: application/json' -d '{}' >/dev/null
sleep 1.2
echo "    live SSE statuses received: $(grep -oE 'status: [a-z_]+' /tmp/shop_sse.txt | tr '\n' ' ')"

echo ">>> SLICE UP. shop is serving behind orchd + service in fd-handoff mode."
