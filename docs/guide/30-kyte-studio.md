# 30. Kyte Data Studio

Kyte Data Studio is a database GUI with a VS Code style layout. It connects to five
database engines, browses their schema, runs queries, and creates tables and indexes,
all from a single window. It is itself a Kyte web application: it dogfoods the same
stack you read about earlier in this guide, vertical-slice `RouteHandler`s
([Chapter 17](17-web.md)), `.kyx` hypermedia views, htmx for partial page swaps, a
Monaco SQL editor, and Tailwind styling. It runs as a local web server you open in a
browser, and a native webview build hosts that same server in a desktop window.

## What you can connect to

Studio speaks to five engines through the standard Kyte drivers:

- **kaidb** ([Chapter 29](29-kaidb-driver.md))
- **PostgreSQL**, **MySQL**, and **SQL Server** (the SQL drivers from
  [Chapter 20](20-database-drivers.md))
- **MongoDB** (documents)

You can hold **several connections open at once** and switch the active one from the
toolbar. When you add a connection, Studio **probes it live** before saving it (a
`SELECT 1` for the SQL engines, a collection listing for MongoDB), so a bad host or
password is caught immediately rather than on your first query. Connections live for
the session; they are not persisted across restarts.

## Running it

Studio is built and run like any Kyte program. In the `kyte-studio` repository:

```sh
# build the styles once (Tailwind), then the app
npm run css
kyte build
```

That produces the binary at `build/debug/bin/kyte-studio`. Run it and open the URL it
prints:

```sh
./build/debug/bin/kyte-studio
# listening on http://127.0.0.1:8080
```

The listen port comes from `app.yaml` and can be overridden with `--port`:

```sh
./build/debug/bin/kyte-studio --port 9000
```

Static assets (the Monaco editor, the compiled CSS, icons) are served from
`wwwroot/`. The desktop build wraps this same server in a native webview window.

## The workspace

The window follows the familiar editor layout: an **activity bar** and an
**explorer** panel on the left, an **editor with tabs** in the centre, a
**results and messages** pane below it, a **status bar**, and a **toolbar** that shows
the active connection. A **light and dark theme** toggle is remembered across visits
and kept in sync with the editor. The chrome (status bar, toolbar, title) refreshes
automatically whenever you connect or switch connections.

## Browsing schema

The explorer shows every connection as a root. Expanding the active one lists its
**tables** (for the SQL engines) or **collections** (for MongoDB). Opening a table
shows its **columns** (name, data type, whether it is nullable, and whether it is part
of the primary key) and its **indexes**. Studio reads this from each engine's own
catalog: `sys.*` for kaidb, and `information_schema` plus the engine specific index
views for PostgreSQL, MySQL, and SQL Server. System tables are filtered out so you see
only your own objects.

## Running queries

Type SQL into the Monaco editor and run it against the active connection. The
**results grid** shows the columns and rows, renders `NULL` distinctly from an empty
string, reports how long the query took, and shows the row count. Large results are
**capped at 1000 rows** with a clear "showing the first N of M" notice, so a `SELECT *`
on a big table stays responsive.

For a MongoDB connection, the query box takes a small find syntax,
`<collection> [field=value]`, and runs a `find` with an optional equality filter,
returning the matching documents as JSON.

## Creating tables and indexes

Studio can create schema objects without hand-writing DDL:

- **Create Table**: give a table name and one `name type` per line. The column type
  dropdown is **engine aware**, so you get `jsonb` and `uuid` on PostgreSQL, `JSON` on
  MySQL, `NVARCHAR` and `UNIQUEIDENTIFIER` on SQL Server, and `INTEGER` and `TEXT` on
  kaidb. You can mark a primary key.
- **Create Index**: give a name, table, and columns, choose unique or not, and pick an
  **engine specific method** where the engine offers one (`btree`, `hash`, `gist`,
  `gin`, `brin` on PostgreSQL, `BTREE` or `HASH` on MySQL, `CLUSTERED` or
  `NONCLUSTERED` on SQL Server).

Identifiers are sanitised before the statement is built. When a create succeeds, the
dialog closes and the explorer refreshes so the new object appears at once. DDL is
offered only for the SQL engines; for MongoDB, Studio tells you plainly that create
statements do not apply.

## Good to know

- Studio is **single user** and keeps **one connection active** at a time, in line
  with Kyte's single-reactor web model ([Chapter 17](17-web.md)). Open as many
  connections as you like and switch between them; queries run against the active one.
- It is a **read, query, and schema** tool today: browsing, running queries, and
  creating tables and indexes. Row-level cell editing is not part of it yet.
- MongoDB browsing and find are wired up and work on a best-effort basis.
- Configuration comes from `app.yaml`, following the file-based config convention used
  across Kyte apps, so there are no environment variables to set.
