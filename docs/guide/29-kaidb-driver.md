# 29. Connecting from Kyte

A Kyte application talks to kaidb through the `kyte-kaidb` driver package. Like the
other database drivers in [Chapter 20](20-database-drivers.md), it implements the
shared `Connection` and `Driver` traits from `data.db`, so the query and exec code you
write against it is the same code you would write against any other Kyte driver. The
data access layer above it, the ORM and the `Repository<T>` pattern from
[Chapter 18](18-data-access.md), works over kaidb without change.

## Adding the driver

Fetch the package with `kyte get`, which appends it to your `project.json` and
resolves it:

```sh
kyte get https://github.com/kytelang/kyte-kaidb
```

```json
{
  "dependencies": ["https://github.com/kytelang/kyte-kaidb"]
}
```

Then import it. The module name is `kaidb`:

```kyte
import kaidb;
```

## Connecting

The connection string uses the `kaidb://` scheme:

```
kaidb://user[:password]@host[:port]?db=<name>&tls=<mode>&tlsCAFile=<pem>
```

The parts and their defaults are:

- `user` : defaults to `admin`. A `user:password@` prefix overrides it.
- `password` : defaults to empty.
- `db` : the database, defaults to `kyte`.
- `tls` : `false` by default; set `true` or `verify`.
- `tlsCAFile` : path to a PEM file when verifying TLS.

You can also pass a bare `host:port`.

There are two ways to open a connection. `connectKaidb` returns the concrete
`KyteConnection`, which also exposes the kaidb specific fast paths. `KyteDriver` is
the seam standard driver whose `connect` returns a `Connection`, which is what you
hand to a pool or the ORM.

```kyte
import kaidb;
import data.db;

async fn main() {
    let conn = await kaidb.connectKaidb("kaidb://admin@127.0.0.1:3009?db=shop");

    let params = List<DbValue>();
    params.push(db.dbInt(2));
    let rs = await conn.query("SELECT id, customer FROM ord WHERE id = ?", params);
    // iterate rs.rows and rs.columns, or bind rows to a struct with the ORM.

    conn.close();
}
```

Note the `?` placeholder: kaidb uses positional `?` markers, not `$1`. Parameters are
supplied as a `List<DbValue>` built with the usual constructors (`db.dbInt`,
`db.dbText`, `db.dbLong`, and so on), exactly as in
[Chapter 18](18-data-access.md).

## The connection surface

`KyteConnection` carries the standard `Connection` methods, all `async` so you
`await` them:

- `query(sql, params)` : run a query and get a `ResultSet`.
- `exec(sql, params)` : run a statement and get an `ExecResult` with the rows
  affected.
- `prepare(sql)`, `queryPrepared(stmt, params)`, `execPrepared(stmt, params)` :
  prepared statements. kaidb emulates these on the client, substituting parameters
  before sending, so they are a convenience rather than a server side plan cache.
- `begin()`, `commit()`, `rollback()` : transaction control.
- `setTimeout(ms)` and `close()`.

It also exposes two kaidb specific helpers: `queryWire(sql, params)` returns raw wire
rows for the zero copy binding path, and `execPipelineLoad(sqls, window)` pipelines a
batch of statements for fast bulk loading.

## Concurrency: use a pool

A single kaidb connection serves **one query at a time**. If a second call comes in
while one is in flight, it is rejected with `connection busy: concurrent use`. A
server that handles concurrent requests should therefore borrow connections from a
pool, exactly as shown for the other drivers in
[Chapter 20](20-database-drivers.md):

```kyte
import kaidb;
import pool;

let p = pool.Pool(KyteDriver(), "kaidb://admin@127.0.0.1:3009?db=shop", 8);

let conn = await p.acquire();   // borrow a live connection
// ... use conn ...
p.release(conn);                // return it to the pool
```

The same `Pool` type backs every Kyte driver, so the pooling code you already know
works here without change.

## Binding rows to structs

Because the driver implements the shared seam, the ORM helpers bind kaidb rows to
your types just like any other database. Mark a struct `@serializable` and query with
the ORM, as in [Chapter 18](18-data-access.md):

```kyte
@serializable
struct Order {
    pub id: int,
    pub customer: string,
    init() { self.id = 0; self.customer = ""; }
}

let params = List<DbValue>();
params.push(db.dbText("paid"));
let orders = await orm.queryAs<Order>(conn, "SELECT id, customer FROM ord WHERE status = ?", params);
```

## Where to go next

- [Chapter 27, kaidb SQL reference](27-kaidb-sql.md) for the SQL you will be writing.
- [Chapter 18, data access and the repository](18-data-access.md) for the ORM and
  `Repository<T>` layer that sits above the driver.
- [Chapter 20, database drivers](20-database-drivers.md) for the shared `Connection`
  and `Driver` model and the `Pool` type.
