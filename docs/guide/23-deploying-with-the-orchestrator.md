# 23. Deploying with Kynator

You have a PostgreSQL-backed web service (Chapter 18). This chapter runs it in production shape: several
replicas behind a load balancer, supervised and kept at their desired count. Kyte ships **Kynator**, the
Kyte-native orchestrator, for exactly this. It is a container-free, Kubernetes-style control plane that
runs your workloads as ordinary native binaries (no images, no container runtime), split into a handful
of binaries that mirror the Kubernetes control-plane / data-plane split.

Kynator's own configuration (workload specs, the leader lease, cluster membership) is a tiny, low-churn
data set: a few megabytes even across thousands of apps. So it does not run a database of its own. That
state lives in `artifactd`, the same content-addressed blob service that already distributes your deploy
binaries, which hosts a small key-value config store beside the blobs. There is no separate database
process in the control plane to stand up, secure, or back up.

`docs/guide/examples/run-live.sh` runs everything in this chapter against the real binaries.

Kynator runs on **Linux only**: its zero-downtime data plane passes sockets between processes with a
POSIX mechanism that has no portable equivalent, so it is a Linux production concern; treat macOS and
Windows as development hosts. There is nothing separate to build or install: Kynator is built and
published as part of the Kyte release, so the four daemons (`artifactd`, `kynatord`, `kynatorctl`,
`service`) land in `~/.kyte/bin` with the toolchain (via `install.sh`, or the
`kynator-<version>-linux-<arch>.tar.gz` bundle in the release) and are on your `PATH` next to `kyte`.

The rest of this chapter explains the binaries, the manifest, and the config store.

## The binaries

The Kyte release installs these into `~/.kyte/bin`; each is a separate daemon:

| Binary       | Plane / role                                                                                                                                     |
| ------------ | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| `service`    | data plane: an L7/L4 reverse proxy and load balancer in front of your app replicas, and the fd-handoff gateway.                                  |
| `kynatord`   | control plane: reconciles desired vs actual replicas, runs health probes, publishes service discovery, runs the HA leader lease, writes metrics. |
| `kynatorctl` | operations: an offline CLI over a config-store dump. Inspect it, manage cluster membership, print a rolling-upgrade plan.                        |
| `artifactd`  | the content-addressed artifact origin: a blob server that distributes deploy binaries by hash.                                                   |
| `orchweb`    | an optional, best-effort control-plane web UI.                                                                                                    |

The core set is `service`, `kynatord`, `kynatorctl`, and `artifactd`; `orchweb` is an optional UI. Every
example below invokes them by name, assuming `~/.kyte/bin` is on your `PATH`.

`artifactd` and the blob store behind it are the subject of the next chapter (Chapter 24, artifact
delivery); this chapter focuses on running and balancing your replicas.

## The shape of a deployment

Kynator runs your app as several replicas fronted by the `service` gateway. There are **two data-plane
shapes**, and the manifest's `lb.handoff` selects one. Which you get changes how the pieces wire
together, so this is the first thing to be clear on.

**fd-handoff (the default, `handoff: true`, `network.expose: gateway-only`).** The replicas have **no
public TCP port**; the gateway owns the single front port and hands each accepted client socket to a
replica over an AF_UNIX rendezvous. Crucially, `kynatord` **launches the gateway itself** for a handoff
workload (this is why the kynatord config needs `servicePath`, below), so you run only `kynatord`:

```
              client traffic
                    |
             service gateway   (front TCP port = network.servicePort, default :8080)
                    |   binds  /tmp/kyte-<name>.sock   (AF_UNIX rendezvous)
        SCM_RIGHTS  |   passes each accepted client fd to a replica, then steps out of the path
              +-----+-----+
         replica A     replica B         <- your app; NO listening TCP port (gateway-only)
              \\           /
               PostgreSQL (:5432)        <- YOUR app's data (the products table)

   kynatord   reconciles the replicas AND launches the gateway; its own state lives in artifactd (:8135)
```

**classic L7 byte-forwarding (`handoff: false`, or `network.expose: public`).** Each replica binds its
own port (`basePort + i`), `kynatord` writes a discovery file, and `service` reads that file and
byte-forwards to the replicas. You run `service` yourself (or point a static `service.json` at the
replicas). Use this when the replicas are not co-resident with the gateway; the `service` config and the
discovery file below describe this mode.

Two stores with two jobs, and they are separate. Your **application** keeps its data in whatever
database it chose in Chapter 18 (here PostgreSQL, holding the `products` table). **Kynator** keeps
its own control-plane state (cluster membership, workload definitions, the leader lease) in `artifactd`'s
config store. Kynator does not touch your app's database, and your app does not touch the config
store.

## service: the data plane

`service` reads a JSON config and load-balances across a set of backends. It reads its config path from
`SERVICE_CONFIG` (default `service.json`), and `KYTE_PORT` overrides the listen port. The minimal config:

```json
{
  "listenHost": "127.0.0.1",
  "listenPort": 8090,
  "strategy": "roundrobin",
  "health": {
    "enabled": true,
    "path": "/",
    "intervalMs": 2000,
    "timeoutMs": 1000,
    "rise": 1,
    "fall": 3
  },
  "backends": [
    { "host": "127.0.0.1", "port": 8080, "weight": 1 },
    { "host": "127.0.0.1", "port": 8081, "weight": 1 }
  ]
}
```

Run it, or lint the config without serving:

```sh
service service.json --check     # validate, print backend count + strategy, exit
service service.json             # serve; KYTE_PORT overrides listenPort
```

Strategies are `roundrobin`, `weighted`, `leastconn`, and `consistenthash`. Active health checks poll
the health path; a backend is taken out after `fall` consecutive failures and returned after `rise`
successes. `service` refuses to start with zero live backends, so a misconfigured pool fails loudly
instead of silently black-holing traffic.

Your app already supports running many replicas on one host: `main_postgres.ky` honours `KYTE_PORT`, so
`KYTE_PORT=8080 ./webapp` and `KYTE_PORT=8081 ./webapp` give you two replicas for service to balance.

> **Note.** `service` runs on the reactor-native socket path (the same one the web server uses in
> Chapter 17): it binds, accepts, forwards to a backend, and streams the response back, load-balancing
> across the replicas. It keeps a **keep-alive pool of backend connections** (per reactor) and reuses a
> warm one per request instead of a fresh TCP handshake, which is the main throughput lever; health
> probes share the same pool. To use more cores, run N single-reactor `service` instances behind
> SO_REUSEPORT.

## kynatord: the control plane

Where `service` moves traffic, `kynatord` keeps the replicas alive. It reconciles the actual set of running
replicas against the desired count on a fixed loop, runs async health probes, and, when configured,
publishes a service-discovery file that `service` reads instead of a static backend list, plus a
Prometheus metrics file. It reads its config from `ORCHD_CONFIG` (default `kynatord.json`) and has no listen
port of its own.

```json
// standalone: reconcile a local manifests/ dir. servicePath is REQUIRED to serve a handoff workload.
{
  "manifestsDir": "manifests",
  "reconcileMs": 2000,
  "nodeId": "node-1",
  "servicePath": "/home/you/.kyte/bin/service",
  "discoveryFile": "discovery.txt",
  "metricsFile": "metrics.prom"
}
```

For the HA path, add a `store` block pointing at artifactd:

```json
{
  "nodeId": "node-1",
  "reconcileMs": 2000,
  "servicePath": "/home/you/.kyte/bin/service",
  "store": { "enabled": true, "addr": "127.0.0.1:8135", "token": "", "tls": false }
}
```

```sh
kynatord kynatord.json --check       # validate and exit
kynatord kynatord.json               # run the reconcile loop
```

**`servicePath`** is the path to the `service` binary, and it is what makes kynatord launch a companion
gateway for every handoff workload: with it set, a `handoff: true` app named `web` also gets a `web-svc`
job running `service` on that workload's rendezvous and `network.servicePort`. **Omit it and a handoff
workload's replicas start but nothing binds the rendezvous, so the front port serves nothing**. This is
the most common "it deployed but `curl` returns `000`" mistake. It is not needed for the classic L7 mode,
where you run `service` yourself.

The `store.enabled` flag chooses kynatord's mode. With the store disabled it runs **standalone**: it
reconciles from `manifestsDir` with no config store and no leader lease (the simplest way to run one
node, and what the walkthrough below uses). With the store enabled it runs the **HA path**: it points at
`artifactd`'s config store (`addr` is artifactd's host:port, `token` is the same deploy bearer token
artifactd guards its routes with, `tls` selects https), takes the leader lease, and reconciles desired
state read from the store. Both are covered below.

## The declarative manifest

The workload you want kynatord to run is described declaratively. There are two schemas in the package, and
it is worth knowing which is which.

The current schema is a **YAML manifest**, parsed by `src/orch/manifest.ky`. The canonical example is
`examples/manifests/shop.yaml`:

```yaml
apiVersion: kyte/v1
kind: App
metadata:
  name: shop
workload:
  # A local path (binary:) OR a content-addressed digest (artifact:). Here we run a locally built binary
  # and select its config profile with an argument. The deploy action can instead fill in artifact: with
  # the sha of the binary it uploaded, so the manifest names the exact bytes to run.
  binary: ./build/release/bin/webapp
  args:
    - --config
    - prod
  restartPolicy: always # always | on-failure | never
replicas:
  min: 2
  max: 6
autoscale:
  enabled: true            # scale to hold the metric near `target`, like a k8s HPA
  metric: inflight         # inflight (in-flight requests/replica) | cpu (percent of one core/replica, Linux)
  target: 8                # inflight: ~8 in-flight requests per replica; cpu would be e.g. 70 (= 70%)
  intervalMs: 2000         # optional control-loop period
lb:
  strategy: roundrobin # roundrobin | weighted | leastconn | consistenthash
  handoff: true # fd-passing data path; app has no public TCP port
health:
  path: /healthz
  intervalMs: 2000
  timeoutMs: 1000
  rise: 2
  fall: 3
network:
  expose: gateway-only # gateway-only (handoff on mac/win, veth on linux) | public
routes:
  - /api/products
  - /api/orders
resources:
  cpuMilli: 500
  memMaxBytes: 268435456
  pidsMax: 128
migrate: # optional: run `binary --migrate` to success BEFORE rolling (see "Schema migrations" below)
  args:
    - --migrate
  timeoutMs: 120000
```

`manifest.ky` gives you `parseManifest(text)`, `validateManifest(m)` (returns `""` when valid),
`toYaml(m)` (round-trips), and `toSpec(m)`, which lowers a manifest to the internal run spec the
supervisor acts on.

### Where the app's own config lives

The manifest above describes only how Kynator _runs_ the app; it does not carry the app's own
configuration. Kyte keeps application config **file-based and outside Kynator on purpose**. The
app reads it from an `app.yaml` at the project root through the framework loader `web.config`, which the
framework calls once when `App()` is constructed and exposes as `app.config`:

```kyte
// app.yaml at the project root
config:
  port: 8080
  logLevel: info
```

```kyte
// in main(): read a value with a default, or bind a typed section
let port = app.config.port(8080);           // --port argv, else config.port, else the default
let db = app.config.bind<DbSettings>("db"); // an @serializable section
```

Kynator never injects app config as environment variables (co-located apps would collide on the
same names), and kynatord does not parse an app `config:` section even if one is present in the manifest
file: `src/orch/manifest.ky` deliberately ignores the `config:` key when binding a `Manifest`, and
`src/orch/spec.ky` states the same. What Kynator does pass to a replica is operational: the
`--config <profile>` argument from `workload.args` (selecting, say, the `prod` profile) and the port. So
the same binary runs locally with no Kynator running, reading its `app.yaml` directly, and works with zero
extra wiring.

> **Gotcha: replicas inherit kynatord's working directory.** kynatord spawns each replica with its own
> current directory, not the app's project folder, so **relative paths in the app resolve against wherever
> kynatord runs**. In particular `app.useStatic("/", "./wwwroot")` will 404 the static home page unless a
> `wwwroot/` happens to sit beside kynatord. Use an absolute static path, run kynatord from the app's
> directory, or serve assets through the artifact. Handler routes (e.g. `GET /api/products/{id}`) are
> unaffected, since they do not touch the filesystem.

There is also a **legacy JSON `Spec`** schema in `src/orch/spec.ky`, parsed by `parseSpec(text)`. It
carries the same intent in a flatter, older shape (`name`, `binaryPath`, `args`, `restartPolicy`,
`replicas`, cgroup limits, probe settings, handoff settings, and an `artifact` field for hash-addressed
binaries, which the next chapter covers). New manifests should use the YAML form; the JSON `Spec` is
still parsed for existing deployments.

## The artifactd-hosted config store

When `store.enabled` is set, kynatord reaches its config store over HTTP at `artifactd`. The `store` block
becomes a base URL through the `storeBaseUrl` helper (in `src/cfg/config.ky`): `http://host:port`, or
`https://host:port` when `tls` is set. There is no database connection string and no database process,
which is the whole point of the move: the control-plane data set is a few megabytes, and it never needed
a general database. It needed exactly four things, and a small key-value store gives all four: mutable
named keys, an atomic compare-and-set (the leader-lease split-brain guard), prefix listing, and a
since-revision watch.

kynatord opens the store in its HA path like this:

```
let base = config.storeBaseUrl(c.store);
let store = httpconfig.HttpConfigStore(base, c.store.token);
let _s = await store.ensureSchema();      // a no-op ping; artifactd self-initialises
```

`HttpConfigStore` (in `src/store/httpconfig.ky`) is an etcd-shaped key-value client: a monotonic global
revision, a per-key modification revision, prefix listing, compare-and-swap on a revision, delete, and a
poll-based watch. Each method is one request to artifactd's `/cfg/*` routes, guarded by the same deploy
token. The keys it persists are worth knowing:

- desired workload state under the `workloads/` prefix,
- the leader lease under `leases/kynatord`,
- cluster membership under `members/<id>`.

The store logic itself is the same in-memory core, `ConfigStore` in `src/store/config.ky`, that the
offline `kynatorctl` and the backup tooling operate on. artifactd hosts one instance of it behind its
routes (`src/artifacts/cfgstore.ky`), snapshots it to a file after every write so it survives a
restart with each key's revision intact, and serves one request at a time on its single reactor. That
last point is what makes the leader election correct: every compare-and-set is a single synchronous call
into one store, so two racing kynatord nodes are serialised and exactly one wins an epoch. It is a simpler,
more obviously-correct arbiter than a distributed transaction.

**One honest caveat.** artifactd is a single coordination point, exactly as a shared database would have
been. Multiple kynatord nodes fail over correctly against it, but making the coordinator _itself_ highly
available (a replicated, standby artifactd) is a separate, larger piece and is not built yet. For a
single artifactd with several kynatord nodes, failover is correct today.

## Discovery file to load balancing

kynatord and service meet through a small discovery file rather than a shared socket.

The writer side is kynatord's nativelet (`src/orch/nativelet.ky`). Each reconcile tick it renders one
`name=host:port` line per replica and atomically writes the discovery file. With `basePort` set on a
workload, replica `i` advertises as `host:(basePort + i)`; otherwise replicas share the probe port.

The reader side is `service`. Given a discovery file and a service name, it reads back every
`name=host:port` line for that name and adds each `host:port` to its proxy pool. So a `service`
configured with `discoveryService: "web"` load-balances across whatever replicas kynatord currently
advertises, and scaling up or losing a replica reshapes the pool without editing service's config.

The division of labour is deliberate: kynatord advertises the desired topology, and the data plane owns
liveness. service's own active health checks prune any advertised endpoint that stops serving, so a
replica that has died but not yet been removed from the file still gets taken out of rotation.

## Health, metrics, and readiness

This is a place where the earlier revision of this chapter drifted, so read it carefully.

`kynatord` does **not** serve `/healthz` and `/readyz` as HTTP routes. It has no listen port. Instead,
`src/orch/health.ky` computes health as plain data:

- `healthy()` is true when the config store is reachable.
- `ready()` is true when the store is reachable and the node's role is one of leader, standby, or
  standalone.
- `healthzText()` renders `"ok"` or `"degraded"`; `readyzText()` renders `"ready"` or `"not ready"`.

These are report strings a process computes, useful for a supervisor or a probe wrapper, not endpoints a
daemon listens on. What kynatord actually emits is the `/metrics` surface, and it emits it as a **file**:
`renderMetrics` produces Prometheus text that kynatord writes to the path in `metricsFile`, for a
node_exporter textfile collector to pick up. The metrics include `orch_up`, `orch_ready`,
`orch_store_reachable`, `orch_leader_epoch`, `orch_workloads_total`, `orch_running_total`,
`orch_under_provisioned`, `orch_reconcile_latency_ms`, and per-workload
`orch_workload_running/desired/restarts`.

If the store becomes unreachable, the HA reconcile tick sets `storeReachable` false, the node steps down,
and the health report flips `ready()` to false, so a load balancer or supervisor watching readiness stops
sending it work.

`service`'s own health checks, described earlier, are a separate mechanism: they decide which backends
receive traffic.

## Rolling upgrades and high availability

There are two rolling mechanisms at two levels.

**Workload-level replica replacement** happens inside a node. The supervisor
(`src/orch/supervisor.ky`) can retire the oldest replica gracefully (SIGTERM, then a timed grace
window, then SIGKILL) and spawn a fresh one, and it can swap in a changed spec without restarting
replicas that are already running the right thing. On a detected spec change the nativelet replaces one
replica per grace window until the roll is complete, so a config change rolls through the replicas rather
than bouncing them all at once.

**Node-level rolling upgrade** happens across nodes, driven by the leader lease. `src/orch/rollout.ky`
walks the nodes one at a time: if a node is the live leader, it releases the lease and promotes a peer
_before_ the upgrade so leadership is never lost; it upgrades the node; the node rejoins as a standby; and
a failed upgrade rolls back and stops the roll. `kynatorctl upgrade-plan <file>` prints this node order so
you can review it before it touches a live cluster.

**The HA leader lease** underneath all this is in `src/orch/asynclease.ky` (`AsyncLeaderLease`; there is
a synchronous sibling in `lease.ky`). kynatord builds it in its HA path against the `leases/kynatord` key with
a TTL of `max(reconcileMs * 5, 15000)` ms. The lease value encodes `holder|epoch|deadlineMs`. Acquisition
is a compare-and-swap on the lease key, and the epoch is bumped on every takeover. Safety rests on that
**fencing epoch**, not on wall-clock time: the CAS guarantees exactly one winner per epoch, and a new
leader raises the store's write fence (a `/cfg/epoch` call to artifactd) so a stale former leader's spec
writes are rejected. Each reconcile tick renews or acquires the lease, guards against a degraded store by
stepping down when it is unreachable, and only the confirmed leader reads `workloads/` and reconciles
from it.

## Schema migrations before a rollout

A new version of an app often needs a schema change, and during a rolling update the old and new
versions run against the same database for a window. Kynator handles this with a gated pre-rollout step:
before it starts or rolls the replicas for a changed workload, it runs a one-shot migration to success,
and only then shifts traffic. A failed migration aborts the rollout and leaves the last-good replicas
serving, so you never end up with a half-migrated fleet.

The migrations live inside the app itself, so the code and its schema never drift and there is no separate
tool to version. `kyte init web` scaffolds `src/migrations.ky` with an ordered list, one entry per change:

```kyte
import data.migrate;
import list;

pub fn all(): list.List<migrate.Migration> {
    let ms = list.List<migrate.Migration>();
    ms.push(migrate.migration(
        1,                              // version: unique, ascending, applied in order
        "create_products",
        migrate.table("products").id()
            .column("name", "TEXT", "NOT NULL")
            .column("price", "BIGINT", "NOT NULL")
            .toSqlIfNotExists(),        // up: moves the schema forward
        migrate.dropTableSql("products")));  // down: reverses this exact step
    return ms;
}
```

The same binary runs the list when it is started with `--migrate` (see the scaffolded `main.ky`): it
applies every migration whose version is not yet recorded, in order, then exits without serving. Point a
real database connection at `migrate.run(conn, migrations.all())` and it returns a `MigrateReport`; a
non-empty `err` means you return a non-zero exit code, which is exactly what the orchestrator gates on:

```kyte
let rep = await migrate.run(conn, migrations.all());
if (!rep.ok()) { console.log("migrate failed: " + rep.err); return 1; }
console.log(`migrated: ${rep.applied} applied`);
return 0;
```

`migrate.run` is safe to call from several processes at once: it records applied versions in a
`schema_migrations` ledger table in your own database, applies each step and its ledger row in one
transaction (so a crash never leaves a step applied-but-unrecorded), and takes a portable single-row lock
(`schema_migrations_lock`) so that if N replicas ever start together, exactly one migrates and the rest
find nothing pending. In the orchestrator's gated model the lock is always free, because the migrate step
runs once, on its own, before any replica starts.

You wire the gate in the manifest with a `migrate:` block. It names the args the workload's binary is run
with (conventionally `--migrate`) and an optional timeout:

```yaml
migrate:
  args:
    - --migrate
  timeoutMs: 120000
```

On a workload change, the reconcile loop runs `binary --migrate` once, to completion, against that
environment's database. It runs at **deploy time**, not build time: CI pushes the artifact by sha to
`artifactd` with no access to any database, and the same artifact is later promoted through staging and
production, migrating each environment's own database as it is deployed. If the one-shot exits 0 the roll
begins; any other exit code aborts the rollout and keeps the existing replicas serving, and the next
reconcile tick retries, so a transient database outage self-heals once it clears.

The discipline that makes this safe is that migrations must be **expand-only** during the window both
versions run. Add tables, add nullable columns, add indexes: the still-running old version tolerates all
of these. Do not `DROP`, `RENAME`, `ALTER` a column's `TYPE`, or `SET NOT NULL` in the same release as the
code that needs it, because that breaks the old version mid-rollout. Ship a destructive or tightening
change as a separate, later release, after every replica already speaks the new schema. `migrate.lintExpandOnly`
(and `migrate.lintAll` over a whole list) flags the risky statements for you, so a pre-deploy check can
warn before the change ever reaches the orchestrator.

## Zero-downtime fd-handoff

The `handoff: true` line in the manifest selects a zero-copy data path that lets you replace an app
replica without dropping in-flight connections. It is POSIX-only by design.

In handoff mode `service` is an out-of-path L4 gateway. It binds an **AF_UNIX** rendezvous socket
alongside the front TCP port. Each backend app connects to the rendezvous as a control channel. On a new
client connection, `service` picks a backend and passes the client socket file descriptor to that app
over the control channel using **`SCM_RIGHTS`** ancillary data (`socket.sendFd`), then closes its own
copy. The app receives the descriptor with `socket.recvFd`, owns the socket, and replies to the client
directly. `service` is out of the data path entirely, so restarting or replacing a replica does not sever
connections the other replica is already serving.

Two details that look like bugs if you get them wrong:

- The rendezvous path is `/tmp/kyte-<name>.sock`, and the **short path is deliberate**. AF_UNIX
  `sun_path` caps at roughly 104 bytes on macOS and 108 on Linux. Do not "portably" swap `/tmp` for
  `$TMPDIR` or `dir.tempDir()`; `/var/folders/...` overflows `sun_path` and breaks the macOS bind.
  `KYTE_HANDOFF_SOCK` overrides the path when you need to, and the default in `bin/service.ky` is
  `/tmp/kyte-service.sock`.
- It is same-host by design. Passing a file descriptor cannot cross a kernel, so the handoff fits
  co-resident replicas on one node, not replicas spread across machines.

On Windows the `socket.sendFd`/`socket.recvFd` stubs return -1: the handoff compiles but does not run
there. The mechanism has no direct Windows equivalent (`SCM_RIGHTS` hands a descriptor to whoever holds
the other end, whereas `WSADuplicateSocket` prepares a duplicate for a process named by PID), so a
Windows port is explicitly not planned. Kynator's production target is Linux; macOS and Windows are
development hosts (see [STABILITY](../STABILITY.md)).

## kynatorctl: operating the config store offline

`kynatorctl` is deliberately offline. It works on a backup dump of the config store, a `key<TAB>value` file,
so you can inspect and repair cluster state without a running control plane. Its real subcommands are:

```sh
kynatorctl inspect store.dump                 # count + list keys
kynatorctl members store.dump                 # list cluster members
kynatorctl member add store.dump node-4 10.0.0.4:7004
kynatorctl member remove store.dump node-2
kynatorctl upgrade-plan store.dump            # print the safe rolling-upgrade node order
```

`upgrade-plan` prints the per-node order described above: it drains a node if it is the leader, upgrades
it, then lets it rejoin, so a rolling upgrade never takes down the quorum.

Backup and restore are a supported operation, though they are not a distinct `kynatorctl` subcommand.
`src/orch/backup.ky` provides `dump(store, prefix)` (line-oriented, escaped `key<TAB>value`) and
`restore(store, data)` (re-applies each entry, last write wins). `kynatorctl` is the operator surface over
such a dump: loading a file is a restore into an in-memory store, saving it is a dump. The live config
store itself is durable without any of this: artifactd snapshots it to `<root>/config.snap` after every
write and reloads it on start, so a restart keeps every key at its original revision.

## Foreign workloads: supervising any binary

Kynator is not limited to Kyte apps. It can supervise any self-contained native binary, a Go service, a
Rust daemon, a C# AOT build, or anything that runs as a process, without you rewriting a line of it. This
is the adoption path: point kynator at a binary you already ship. Set `workloadType: foreign` and the
supervisor drops the Kyte conventions that a foreign binary cannot speak.

```yaml
apiVersion: kyte/v1
kind: App
metadata:
  name: checkout-go
workload:
  workloadType: foreign        # kyte (default) | foreign
  binary: ./bin/checkout       # a Go/Rust/C#-AOT binary; artifact: works too (see chapter 24)
  args:
    - serve
  restartPolicy: always
  portEnv: PORT                # the env var the binary reads its port from (default KYTE_PORT)
  workdir: /var/lib/checkout   # working directory for the child ("" inherits kynatord's)
  env:                         # extra environment, as KEY=VALUE entries
    - LOG_LEVEL=info
    - REGION=in
replicas:
  min: 2
  max: 4
network:
  expose: gateway-only         # foreign workloads are always given a real listening port (see below)
  portBase: 9100               # replica i binds 9100 + i; the gateway byte-forwards to it
health:
  probeType: tcp               # http (default) | tcp | exec
  # for probeType: exec, give a command instead; exit 0 means healthy
  # probeType: exec
  # probeCmd: ["/usr/local/bin/healthcheck", "--fast"]
```

What changes for a foreign workload, and why:

- **Port delivery is explicit.** A Kyte app reads `KYTE_PORT`; a foreign binary usually reads its own
  variable, so `portEnv` names it (for example `PORT`). The supervisor sets that variable to the replica's
  assigned port at spawn. Set `portEnv: ""` if the binary only takes a port on the command line, and use
  `network.portFlag` for that.
- **Environment and working directory.** `env` entries are applied on top of the inherited environment,
  and `workdir` sets the child's directory. Both are applied per child at spawn, so co-located workloads
  never collide on a shared process environment.
- **No fd-handoff.** The zero-copy fd-passing data path is a Kyte-only protocol. A foreign workload is
  always steered onto a real listening port (`portBase`), and the `service` gateway byte-forwards client
  connections to it. You do not need to (and cannot) set `handoff` for a foreign workload.
- **No Kyte-only steps.** The pre-rollout `migrate` step and the companion Kyte service are skipped for a
  foreign workload, because they assume a Kyte binary.
- **Health probes it can answer.** A foreign binary need not expose `/healthz`. Choose `probeType: tcp` (a
  bare connect succeeds) or `probeType: exec` (kynatord runs your `probeCmd`; exit 0 is healthy) instead of
  `http`.
- **The exec bit is owned for you.** A binary copied onto the node, or fetched as a content-addressed
  artifact, is made executable (`chmod 0o755`) before the first spawn, so it will not fail with a
  permission error.

A content-addressed `artifact:` may also be a tarball (`artifactKind: tarball`): kynator extracts it into
the workload's `workdir` and runs the (relative) `binary:` from there. Note that pulling a
content-addressed artifact by hash from a remote origin is the deploy integration described in chapter 24;
today a foreign workload with a local `binary:` path runs through the whole supervision, scaling, health,
and byte-forward path end to end.

## Operator quick reference

Everything above from the point of view of the person running a fleet. An operator works with three
surfaces: the manifest (desired state), the live control plane (`kynatord` plus the artifactd-hosted config
store), and `kynatorctl` (offline repair).

Day-to-day tasks:

- **Deploy or change a workload.** Edit the manifest and apply it (drop it in the watch directory, or write
  it to the config store). Kynatord reconciles: it starts missing replicas, replaces changed ones with a
  rolling upgrade, and does nothing for an unchanged spec. A manifest that fails validation is ignored and
  the last good workload keeps serving, so a bad edit never tears down a healthy fleet.
- **Scale.** Change `replicas.min` / `replicas.max`, or let the autoscaler move within that band
  (`autoscale.metric` is `inflight` or `cpu`). Scaling is by instance count; there is no in-process
  concurrency dial.
- **Roll out a new version.** Point `artifact:` (or `binary:`) at the new build. Replicas are replaced one
  at a time, draining each with a real grace window before the next starts, so the workload stays up.
- **Gate a schema migration.** Add `migrate: { args: [--migrate] }` (Kyte workloads only) so the new binary
  runs its own migration to success before any replica is rolled; a non-zero exit aborts the rollout and
  keeps the last good replicas serving. See "Schema migrations before a rollout".
- **Watch health and readiness.** Kynatord supervises process liveness (a crashed replica is respawned) and
  runs the heal probe (`health.type`). The `service` data plane health-checks every backend and gates
  traffic on it. The metrics snapshot exposes desired vs running replicas and cumulative restarts;
  `running < desired` is the under-provisioned signal to alert on.
- **Operate a cluster.** For a multi-node control plane, use `kynatorctl` on a config-store dump to inspect
  keys, list or edit members, and print the safe rolling-upgrade node order (see the section above). It is
  offline by design so you can inspect and repair state without a running control plane.

For the deeper runbooks, leader loss, split-brain, and store-outage handling, see kynator's own repository.

## Configuration reference: every field

Kynator is configured by a handful of small files. This section is the field-by-field reference for
each: what the field is, its default, and where it takes effect. Every field falls back to the default
shown when it is absent, so the shortest useful file is a near-empty one. The three schemas parsed from
disk (`*.yaml` manifest, `service.json`, `kynatord.json`) all **fail loudly on a present-but-wrong-type
field** rather than silently ignoring it, so a typo surfaces at `--check` time.

### The workload manifest (`*.yaml`)

The declarative description of one workload, parsed by `src/orch/manifest.ky`. It is what you commit
and hand to the deploy action, and it lowers to the internal run spec through `toSpec(m)`. Top level:

| Field         | Type   | Default    | Meaning and where it is used                                                        |
| ------------- | ------ | ---------- | ----------------------------------------------------------------------------------- |
| `apiVersion`  | string | `kyte/v1`  | Schema version tag. Only `kyte/v1` exists today; it lets the format evolve later.   |
| `kind`        | string | `App`      | The resource kind. `App` is the only kind.                                          |
| `metadata`    | object | (below)    | Identity of the workload.                                                           |
| `workload`    | object | (below)    | What to run, and how the process is launched.                                       |
| `replicas`    | object | (below)    | The desired replica count (or the band the autoscaler works within).                |
| `autoscale`   | object | (below)    | Optional PID autoscaler policy.                                                     |
| `lb`          | object | (below)    | Load-balancer and data-path selection.                                              |
| `health`      | object | (below)    | Liveness probe settings.                                                            |
| `network`     | object | (below)    | How the workload is exposed to clients.                                            |
| `resources`   | object | (below)    | cgroups-v2 resource limits (Linux).                                                |
| `migrate`     | object | (below)    | Optional pre-rollout database-migration gate.                                      |
| `routes`      | list   | `[]`       | Informational list of HTTP route prefixes the app owns; used for documentation and future path-based routing, not required to run. |

**`metadata`**

| Field  | Type   | Default | Meaning and where it is used                                                       |
| ------ | ------ | ------- | ---------------------------------------------------------------------------------- |
| `name` | string | (required) | The unique workload key. It names the manifest's job, the companion gateway (`<name>-svc`), the handoff rendezvous `/tmp/kyte-<name>.sock`, and the `workloads/<name>` store key. `validateManifest` rejects an empty name. |

**`workload`** (what each replica runs)

| Field          | Type         | Default     | Meaning and where it is used                                                    |
| -------------- | ------------ | ----------- | ------------------------------------------------------------------------------- |
| `binary`       | string       | `""`        | Local path to the executable to run. Used when `artifact` is empty. One of `binary` or `artifact` is required. |
| `artifact`     | string       | `""`        | Content-addressed binary as `sha256:<hex>`. When set, kynatord pulls the blob by hash into its cache and runs the verified copy instead of `binary`. This is the field the deploy action fills in. |
| `args`         | `list<string>` | `[]`        | Extra argv passed to each replica, excluding the binary itself and the injected port. For example `["--config", "prod"]`. |
| `restartPolicy`| string       | `always`    | `always`, `on-failure`, or `never`. Governs whether the supervisor respawns an exited replica. |
| `workloadType` | string       | `kyte`      | `kyte` (default) or `foreign`. A `foreign` binary (Go, Rust, C# AOT) gets no migrate step, no companion Kyte service, and is put on a real listening port the gateway forwards to. |
| `env`          | `list<string>` | `[]`        | Extra environment entries, each a `"KEY=VALUE"` string, applied to every replica. It must be an array, not a YAML map; the parser rejects the map form with a clear error. |
| `secrets`      | `list<string>` | `[]`        | File-mounted secret handles, each `"ENVVAR=/abs/path"`. Only the path is passed, never the secret value. |
| `workdir`      | string       | `""`        | Working directory for each replica. `""` inherits kynatord's own directory. Set it to a tarball artifact's extract dir. |
| `portEnv`      | string       | `KYTE_PORT` | The environment variable the assigned port is delivered through. Many foreign apps read `PORT`. |
| `artifactKind` | string       | `single`    | `single` (the blob is the executable) or `tarball` (the blob is extracted per-workload before running). |

**`replicas`** (desired count)

| Field | Type | Default | Meaning and where it is used                                                               |
| ----- | ---- | ------- | ------------------------------------------------------------------------------------------ |
| `min` | int  | `1`     | Lower bound on running replicas. Must be at least 1. A fixed count is `min == max`.        |
| `max` | int  | `1`     | Upper bound. Must be at least `min`. The autoscaler clamps its output to `[min, max]`.     |

**`autoscale`** (optional). Automatically add or remove replicas based on live load, staying within the `min`/`max` band from `replicas`. You choose what to measure (`metric`) and the value to aim for per replica (`target`); Kynator adds replicas when the measured load is above the target and removes them when it is below. For example `metric: cpu` with `target: 70` keeps each replica around 70% CPU, scaling out under load and back in when it is idle. Fields:

| Field        | Type   | Default    | Meaning and where it is used                                                     |
| ------------ | ------ | ---------- | -------------------------------------------------------------------------------- |
| `enabled`    | bool   | `false`    | Turn the autoscaler on. When off, the count is pinned (usually via `min == max`).|
| `metric`     | string | `inflight` | The regulated signal: `inflight` (in-flight requests, the gateway's own load metric) or `cpu` (the workload cgroup's CPU utilisation, Linux). |
| `target`     | double | `0.0`      | Target value of the metric, per replica. `inflight`: in-flight requests (e.g. `8`). `cpu`: percent of one core (e.g. `70`). The autoscaler adds or removes replicas to hold the metric near this value, like a Kubernetes HPA target. Must be greater than 0 when autoscaling. |
| `intervalMs` | int    | `2000`     | Control-loop period in milliseconds.                                             |

**`lb`** (load balancer and data path)

| Field      | Type   | Default      | Meaning and where it is used                                                     |
| ---------- | ------ | ------------ | -------------------------------------------------------------------------------- |
| `strategy` | string | `roundrobin` | `roundrobin`, `weighted`, `leastconn`, or `consistenthash`. How the gateway picks a replica. |
| `handoff`  | bool   | `true`       | Selects the fd-passing data path (the app receives client sockets over the AF_UNIX rendezvous and has no public TCP port). Set `false` for classic L7 byte-forwarding. See "The shape of a deployment". |

**`health`** (liveness probe)

| Field        | Type         | Default     | Meaning and where it is used                                                    |
| ------------ | ------------ | ----------- | ------------------------------------------------------------------------------- |
| `path`       | string       | `/healthz`  | HTTP GET path the probe hits (expects 2xx/3xx). An empty string means a bare TCP-connect probe. |
| `intervalMs` | int          | `2000`      | Milliseconds between probes.                                                    |
| `timeoutMs`  | int          | `1000`      | Per-probe timeout.                                                              |
| `rise`       | int          | `2`         | Consecutive OK probes needed to return a replica to rotation.                   |
| `fall`       | int          | `3`         | Consecutive failed probes that drain a replica.                                 |
| `probeType`  | string       | `http`      | The supervisor's own heal probe: `http`, `tcp` (bare connect), or `exec` (run `probeCmd`, exit 0 = healthy). This is distinct from the data-plane health checks in `service`. |
| `probeCmd`   | `list<string>` | `[]`        | The argv for an `exec` probe.                                                   |

**`network`** (exposure)

| Field         | Type   | Default        | Meaning and where it is used                                                  |
| ------------- | ------ | -------------- | ----------------------------------------------------------------------------- |
| `expose`      | string | `gateway-only` | `gateway-only` (reachable only through the gateway; fd-handoff on macOS/Windows or a veth namespace on Linux) or `public` (the app binds a host port directly; dev convenience). |
| `portBase`    | int    | `0`            | Used only when `expose: public`: replica `i` binds `portBase + i`. `0` means not directly exposed. |
| `portFlag`    | string | `""`           | Used only when `expose: public`: the flag the port is passed on at spawn, for example `--port`. |
| `servicePort` | int    | `8080`         | The public front port the workload's gateway listens on. Clients hit this; the gateway hands or forwards connections to the replicas. |

**`resources`** (cgroups-v2 limits, Linux; `0` = unset)

| Field         | Type | Default | Meaning and where it is used                                                       |
| ------------- | ---- | ------- | ---------------------------------------------------------------------------------- |
| `cpuMilli`    | int  | `0`     | Milli-CPU cap. `500` = half a core.                                                |
| `memMaxBytes` | long | `0`     | Hard memory ceiling in bytes.                                                      |
| `pidsMax`     | int  | `0`     | Maximum number of processes/threads in the workload's cgroup.                      |

**`migrate`** (optional pre-rollout gate; see "Schema migrations before a rollout")

| Field       | Type         | Default | Meaning and where it is used                                                     |
| ----------- | ------------ | ------- | -------------------------------------------------------------------------------- |
| `args`      | `list<string>` | `[]`    | When non-empty, kynatord runs the workload's own binary once with these args (conventionally `["--migrate"]`) to success before it starts or rolls the app. A non-zero exit aborts the rollout. |
| `timeoutMs` | int          | `0`     | Bounds the migration run. `0` waits indefinitely.                                |

> The app's own `config:` section is intentionally NOT part of this schema. It is the application's
> configuration, read by the app itself from `app.yaml` through the framework loader (`web.config`), and
> kynatord ignores a `config:` key if it appears in a manifest file. See "Where the app's own config lives".

### `service.json` (the data-plane gateway)

Read by `service` from the path in `SERVICE_CONFIG` (default `service.json`); `KYTE_PORT` overrides
`listenPort`. Only needed for classic L7 mode where you run `service` yourself; in the default handoff
mode kynatord launches the gateway for you from `servicePath` and you do not write this file.

| Field                | Type   | Default       | Meaning and where it is used                                             |
| -------------------- | ------ | ------------- | ------------------------------------------------------------------------ |
| `listenHost`         | string | `""`          | Interface to bind. `""` means any interface.                             |
| `listenPort`         | int    | `8080`        | Front TCP port clients connect to. `KYTE_PORT` overrides it.             |
| `timeoutMs`          | int    | `15000`       | Per-upstream I/O deadline.                                               |
| `strategy`           | string | `roundrobin`  | `roundrobin`, `weighted`, `leastconn`, or `consistenthash`.              |
| `health`             | object | (below)       | Active backend health checks (decides which backends receive traffic).  |
| `backends`           | list   | `[]`          | Static backend pool (see below). Used when there is no discovery file.   |
| `discoveryFile`      | string | `""`          | Path to kynatord's service-discovery file. When set, `service` resolves backends from it instead of, or alongside, `backends`. |
| `discoveryService`   | string | `""`          | The service name to read from the discovery file (matches the `name=host:port` lines kynatord writes). |
| `discoveryRefreshMs` | int    | `1000`        | How often `service` re-reads the discovery file and reshapes its pool. Only used when `discoveryFile` is set. |

**`health`** (nested object)

| Field        | Type   | Default    | Meaning and where it is used                                                     |
| ------------ | ------ | ---------- | -------------------------------------------------------------------------------- |
| `enabled`    | bool   | `false`    | Turn active health checks on. (When the `health` block is present but omits `enabled`, it defaults to `true`.) |
| `path`       | string | `/healthz` | HTTP path the check hits.                                                        |
| `intervalMs` | int    | `2000`     | Milliseconds between checks.                                                     |
| `timeoutMs`  | int    | `1000`     | Per-check timeout.                                                               |
| `rise`       | int    | `2`        | Consecutive successes to return a backend to rotation.                           |
| `fall`       | int    | `3`        | Consecutive failures to take a backend out.                                      |

**`backends[]`** (each entry)

| Field    | Type   | Default | Meaning and where it is used                                                        |
| -------- | ------ | ------- | ----------------------------------------------------------------------------------- |
| `host`   | string | (required) | Backend host.                                                                    |
| `port`   | int    | (required) | Backend port.                                                                    |
| `weight` | int    | `1`     | Relative weight for the `weighted` strategy.                                        |

### `kynatord.json` (the control plane)

Read by `kynatord` from the path in `ORCHD_CONFIG` (default `kynatord.json`). kynatord has no listen port
of its own. The `store` block chooses standalone vs HA mode.

| Field               | Type   | Default             | Meaning and where it is used                                     |
| ------------------- | ------ | ------------------- | ---------------------------------------------------------------- |
| `manifestsDir`      | string | `manifests`         | Directory of workload manifests the nativelet reconciles in standalone mode. |
| `reconcileMs`       | int    | `2000`              | Reconcile-loop period. Also sets the lease TTL (`max(reconcileMs * 5, 15000)`). |
| `nodeId`            | string | `node-1`            | This node's identity, used in the leader lease and in logs.      |
| `discoveryFile`     | string | `""`                | Where kynatord publishes its `name=host:port` discovery lines. `""` means do not publish. |
| `advertiseHost`     | string | `127.0.0.1`         | The host `service` should reach the replicas on, written into the discovery file. |
| `store`             | object | (below)             | The artifactd config-store connection. `enabled` chooses standalone vs HA. |
| `metricsFile`       | string | `""`                | When set, kynatord writes Prometheus exposition text here each tick for a node_exporter textfile collector. |
| `crashLoopRestarts` | int    | `5`                 | The per-workload restart count at or above which a crash-loop alert fires in the metrics. |
| `servicePath`       | string | `""`                | Path to the `service` binary. When set, kynatord launches and supervises a companion gateway for every handoff workload. Omit it and a handoff app's front port serves nothing (the most common "deployed but curl returns 000" mistake). |
| `artifactCacheDir`  | string | `./artifact-cache`  | Per-node blob cache an `artifact: sha256:<hex>` resolves into. A missing blob is pulled by hash and verified before it runs. |
| `artifactOrigin`    | string | `""`                | Base URL kynatord pulls blobs from (`GET <origin>/artifacts/<sha>`). `""` falls back to the config store's own URL (the all-in-one dev artifactd). Point it at S3/MinIO/CDN/nginx for a durable, TLS-capable origin. See chapter 24. |
| `artifactToken`     | string | `""`                | Bearer token for the artifact origin. `""` falls back to `store.token`. |

**`store`** (nested object; `enabled` selects HA)

| Field     | Type   | Default          | Meaning and where it is used                                                  |
| --------- | ------ | ---------------- | ----------------------------------------------------------------------------- |
| `enabled` | bool   | `false`          | `false` = standalone (reconcile from `manifestsDir`, no leader lease). `true` = HA path against artifactd's config store. |
| `addr`    | string | `127.0.0.1:8135` | artifactd's `host:port`. Required when the store is enabled.                  |
| `token`   | string | `""`             | The deploy bearer token artifactd guards its routes with. `""` = auth off (dev only). |
| `tls`     | bool   | `false`          | Use `https` for the hop to artifactd.                                        |

### `app.yaml` (your application's own config)

This file belongs to the app, not to Kynator. kynatord never reads or injects it. The framework loader
`web.config` reads it once when `App()` is constructed and exposes it as `app.config`. Its shape is
whatever your app defines under the `config:` root; there is no fixed Kynator schema. The values are read
with a default (`app.config.port(8080)`) or bound to an `@serializable` section
(`app.config.bind<DbSettings>("db")`). See "Where the app's own config lives".

### The legacy JSON `Spec`

`src/orch/spec.ky` defines an older, flatter JSON shape (parsed by `parseSpec`) that carries the same
intent as the YAML manifest: `name`, `binaryPath`, `artifact`, `args`, `restartPolicy`, `replicas`, the
cgroup limits (`cpuMilli`, `memMaxBytes`, `pidsMax`), probe settings (`probePath`, `probePeriodMs`,
`probeFall`, `probeType`, `probeCmd`), handoff settings (`handoff`, `handoffSock`, `servicePort`,
`basePort`, `portFlag`), migration (`migrateArgs`, `migrateTimeoutMs`), and the foreign-workload fields
(`workloadType`, `env`, `workdir`, `portEnv`, `secretRefs`, `artifactKind`). It is still parsed for
existing deployments, but the YAML manifest is the current surface: `toSpec(m)` lowers a manifest to this
same run spec internally, so new work should write YAML.

## The whole loop end to end

`docs/guide/examples/run-live.sh` puts it together against the real binaries. It:

1. connects to PostgreSQL on `127.0.0.1:5432` and seeds a `products` table,
2. builds the PostgreSQL-backed web app (`main_postgres.ky`) and starts two replicas on 8080 and 8081
   via `KYTE_PORT`,
3. exercises the app directly: a `POST /api/products` write through to PostgreSQL and a
   `GET /api/products/1` read back,
4. writes a `service.json` for the two replicas, validates it with `service --check`, starts the
   installed `service` on 8090, and curls `GET /api/products/1` through the proxy three times so you can
   watch the round-robin,
5. seeds a config-store dump (members plus a workload) and runs `kynatorctl inspect`, `kynatorctl members`, and
   `kynatorctl upgrade-plan` over it.

Run it from anywhere; it builds what it needs and cleans up every process on exit:

```sh
docs/guide/examples/run-live.sh
```

## Where to go next

- Chapter 17 for the web app and the reactor-native server this deploys.
- Chapter 18 for the PostgreSQL-backed app and the `postgresql://` connection string your application
  uses (a separate concern from the control-plane config store, which is on artifactd).
- Chapter 24 for artifact delivery: `artifactd`, the content-addressed blob store it also hosts, and
  pulling a deploy binary by hash.
- Kynator's own repository for the full operator reference, including leader loss, split-brain, and
  store-outage runbooks.
