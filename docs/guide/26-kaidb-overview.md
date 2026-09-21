# 26. kaidb overview

kaidb is a durable SQL database engine written in Zig. It gives you real MVCC
transactions, crash recovery, secondary and covering indexes, streaming read
replicas, and a familiar SQL surface, all from a single small server binary with no
external dependencies. It ships as two programs: `kaidb` (the server) and
`kaidb-cli` (a command line client). A Kyte application talks to it through the same
`Connection` and `Driver` vocabulary you already use for the other databases in
[Chapter 20](20-database-drivers.md), using the `kyte-kaidb` driver package covered
in [Chapter 29](29-kaidb-driver.md).

This chapter explains kaidb's design and how to run the server. The next three
chapters cover the SQL it supports, the CLI, and connecting from Kyte.

## The storage model

kaidb is **index-organised (clustered)**: a table *is* its primary key B+Tree, and
the full row lives in the leaf next to its key. This is the same design InnoDB uses,
and it has a direct payoff. A lookup or range scan by primary key finds the key and
the row in the same descent, so it does strictly less I/O than a heap based engine
like PostgreSQL, which has to read the index and then make a second random read into
the heap.

Pages are 16 KiB (four times SQLite's default, twice PostgreSQL's), which shortens
the tree and amortises per-page overhead over more rows.

## What kaidb gives you

- **MVCC transactions.** Each row's latest version is stored inline with a 32-byte
  version header, and older versions live in an undo log. Readers see a consistent
  snapshot and never block writers, and a background writer purges undo versions once
  no transaction needs them.
- **Durability that survives a crash.** Every page mutation is written ahead to the
  WAL, and dirty pages go through a doublewrite buffer, the same torn-write protection
  InnoDB uses, so a `kill -9` in the middle of a write recovers cleanly. Recovery
  repairs torn pages from the doublewrite copy, then replays the WAL in three phases.
  `synchronous_commit` lets you trade per-commit `fsync` latency for durability.
- **Backup and point in time recovery.** Take a consistent physical snapshot as a
  cold backup (`kaidb backup`) or a hot one (`BACKUP DATABASE TO`), and replay
  archived WAL segments forward to any target LSN with `kaidb restore`.
- **A cost based query planner.** It picks index scans, index-only aggregates, and,
  for joins, nested loop versus hash join by estimated cost. Covering indexes are
  answered index-only, with no base-row descent. See [Chapter 27](27-kaidb-sql.md).
- **A concurrent buffer pool.** The pool is sharded into independent instances, each
  with its own lock and CLOCK eviction, so cache hits on different shards proceed in
  parallel. It auto-sizes to roughly half of system RAM, and an optional mmap read
  path borrows a pointer straight into the mapped file with no copy.
- **Fast clustered lookups.** For secondary-index scans, kaidb prefetches the base
  rows ahead of the scan and reuses a base-leaf cursor across a batch, so a range of
  nearby rows is resolved with a single leaf walk. This is more than SQLite does,
  which relies on OS readahead alone.
- **Streaming read replicas.** See the next section.

## High availability and read replicas

kaidb supports primary and follower replication. A primary streams its committed
writes to one or more followers, which you can use as **read replicas** to scale
reads out across machines, and as **standbys** for high availability so a follower
can take over if the primary is lost.

Replication is configured through the server config or environment. On the primary,
enable a replica peer; on the follower, point it at the primary. The default replica
peer port is `3010`.

```json
{
  "replication": { "enabled": true, "address": "10.0.0.2", "port": 3010 }
}
```

Shipping to a follower is asynchronous: the primary commits locally and streams the
change to the follower, and if a follower is briefly unreachable the primary keeps
committing and the follower catches up when it reconnects. A follower can be promoted
to take over as the leader.

## Running the server

The server binary is `kaidb`. With no configuration file present it boots on all
defaults, so a fresh install just runs:

```sh
kaidb
```

Configuration lives in a `db.json` file in the working directory. Every field has a
default, so you only set what you want to change:

| Setting | Default | Meaning |
| --- | --- | --- |
| `address` | `127.0.0.1` | Interface the listeners bind to. |
| wire `port` | `3009` | The binary protocol port (SQL clients and the Kyte driver). |
| HTTP `port` | `3008` | Health and metrics endpoints. |
| `base_dir` | `data` | Directory holding `kaidb.db` and the `wal/` folder. |
| TLS `enabled` | `false` | Whether the wire port requires TLS. |
| `durability.synchronous_commit` | `false` | Whether a commit waits for the WAL flush. |
| `pool_size` | `0` | Buffer pool pages; `0` auto-sizes to about half of RAM. |

A minimal `db.json` that moves the data directory and turns on synchronous commit:

```json
{
  "base_dir": "/var/lib/kaidb",
  "durability": { "synchronous_commit": true }
}
```

### Health and metrics

Alongside the wire port, kaidb serves an HTTP surface on the HTTP port:

- `GET /healthz` : liveness.
- `GET /readyz` : readiness.
- `GET /metrics` : Prometheus metrics.

### Admin subcommands

The `kaidb` binary runs offline maintenance tasks directly on the data directory, so
run them when the server for that directory is stopped (or against a copy):

```sh
# Compact a data file.
kaidb compact <src> <dst>

# Take a hot backup. base_dir must directly contain kaidb.db and wal/.
kaidb backup <base_dir> <dest_dir>

# Restore, with optional point in time recovery.
kaidb restore <snapshot_dir> <dest_base_dir> [--archive=<dir>] [--target-lsn=<N>]

# Rotate a user's password offline.
kaidb passwd <base_dir> <user> <newpassword>
```

## Where to go next

- [Chapter 27, kaidb SQL reference](27-kaidb-sql.md): the exact SQL kaidb supports.
- [Chapter 28, the kaidb CLI](28-kaidb-cli.md): running queries from the terminal.
- [Chapter 29, connecting from Kyte](29-kaidb-driver.md): the `kyte-kaidb` driver.
