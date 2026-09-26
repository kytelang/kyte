# 17. Building a web application

Kyte ships a small, direct web framework in the standard library. There is no
mediator, no dependency-injection container, and no annotation magic in the
request path. A route maps a URL to a handler object, the handler reads its
typed input from the request and returns a response, and you wire the handlers
together in a plain composition root that you can read top to bottom.

The framework is built for **hypermedia** applications: handlers return HTML
fragments that the browser swaps into the page, so most features need no
client-side JavaScript. It works just as well for JSON APIs; the only
difference is what a handler puts in the response body.

The running example for this chapter is the project the toolchain scaffolds
with `kyte init web`. The full source lives in
[`examples/webapp`](examples/webapp), builds offline, and its tests pass with
`kyte test`. Every snippet below is taken from it.

## Vertical slices

The project is organised by **feature**, not by technical layer. Everything one
use case needs (its input type, its handler, its view, its validation) lives in
one folder under `Features/`. This is vertical slice architecture: to change
"create a product" you open one folder, not four parallel `controllers/`,
`models/`, `views/` trees.

```
src/
  main.ky                         composition root
  Domain/
    Entities/Product.ky           the business object (persistence-agnostic)
    Dtos/ProductDto.ky            the shape returned to clients
    Dtos/CreateProductDto.ky
  Features/
    Products/
      routes.ky                   this feature's route table
      CreateProduct/
        command.ky                the write input (a @serializable struct)
        handler.ky                the RouteHandler
        validator.ky              input checks
      GetProductById/
        query.ky                  the read input
        handler.ky
      Shared/
        repository.ky             data access for the feature
        database.ky               an in-memory Connection (the default)
      views/product_card.kyx        an KyX view
  wwwroot/                          static assets
```

## Scaffolding the project

```bash
kyte init web --name shop
cd shop
kyte build
./build/debug/bin/shop      # serves on http://127.0.0.1:8080
```

`kyte init web` writes two manifests, and it is worth knowing which is which:

- **`project.json`** is the Kyte manifest. It carries the project name,
  version, and the list of package dependencies the compiler resolves. This is
  the one the build reads. Chapter 19, Package management, covers it in full.
- **`package.json`** is only for the Tailwind CSS command-line tool (an npm
  dev dependency). The Kyte build ignores it. If you do not use Tailwind you can
  delete it.

## A read slice: get a product by id

A slice starts with its **input type**. For a read that is a `query`: a plain
`@serializable` struct whose fields the framework fills from the request.

```kyte
// Features/Products/GetProductById/query.ky
@serializable pub struct GetProductById {
    pub id: int,
    init() { self.id = 0; }
}
```

The **handler** implements the `RouteHandler` trait from `web.routing`. A
`RouteHandler` is a plain struct that holds its dependencies as fields and
exposes exactly one method, `serve(ctx)`. It reads its typed input with
`ctx.bind<T>()`, does its work, and returns a `Response`.

```kyte
// Features/Products/GetProductById/handler.ky
import web.routing;
import web.response;
import web.status;
import Features.Products.GetProductById.query;
import Features.Products.Shared.repository;
import Features.Products.views.product_card;
import Domain.Dtos.ProductDto;

pub struct GetProductByIdHandler impl RouteHandler {
    repo: ProductRepository,
    init(repo: ProductRepository) { self.repo = repo; }

    async fn serve(self: GetProductByIdHandler, ctx: Context): Response {
        let q = ctx.bind<GetProductById>();
        let found = await self.repo.findById(q.id);
        if (found == undefined) {
            return response.Response(Status.NotFound, "product not found");
        }
        let product = found ?? ProductDto{ id: 0, name: "", price: 0 };
        let html = productCard(product.name, product.price);
        return response.Response(Status.Ok, html)
            .setHeader("Content-Type", "text/html; charset=utf-8");
    }
}
```

`ctx.bind<GetProductById>()` fills `id` from the route parameter `{id:int}`.
The repository returns `ProductDto | undefined`, so a missing id is a plain 404;
there is nothing to catch and no exception to model.

## `ctx.bind`, and where the fields come from

`ctx.bind<T>()` deserialises `T` from ONE merged view of the request, so a
handler never parses a URL or a body by hand. The `Context` builds that view
from, in order:

- cookies,
- the query string,
- path parameters (`{id:int}` and friends),
- and, for `POST`/`PUT`/`PATCH`, the request body: `multipart/form-data`,
  `x-www-form-urlencoded`, or JSON, chosen by the `Content-Type`.

Later sources win over earlier ones, so a path parameter overrides a query
parameter of the same name. Two smaller accessors exist for when you want a
single raw value instead of a bound struct:

```kyte
let raw = ctx.query("q");     // one query-string value, or ""
let ids = ctx.param("id");    // one path parameter, or ""
```

Because a hypermedia form POSTs `application/x-www-form-urlencoded`, the SAME
`ctx.bind<T>()` reads a submitted form with no extra work.

## Views: KyX

View code lives in `.kyx` files. KyX is the same language as `.ky`, just
filed apart so markup stays separate from logic. An KyX element is a `string`,
so views compose directly and expressions embed with `{...}`.

```kyte
// Features/Products/views/product_card.kyx
pub fn productCard(name: string, price: int): Html {
    return <div class="rounded-lg border border-slate-200 p-4 shadow-sm">
        <h3 class="font-semibold text-slate-800">{name}</h3>
        <p class="mt-1 text-sm text-slate-500">{price}</p>
    </div>;
}
```

A `{expr}` interpolation is **HTML-escaped automatically**, so user text like a
product name is safe by default and you never call an escaper. To insert an
already-rendered fragment unescaped (one view composing another), wrap it in
`response.raw(fragment)` from `web.response`. That one escaping rule, escaped by
default and explicit `raw` when you mean it, is what keeps the views free of
cross-site-scripting holes.

## A write slice: create a product

The write input is a `command`, again a plain `@serializable` struct. Command
means write intent (a `POST`/`PUT`/`DELETE`); query means read intent. They are
the same kind of object, named for what they express.

```kyte
// Features/Products/CreateProduct/command.ky
@serializable pub struct CreateProduct {
    pub name: string,
    pub price: int,
    init() { self.name = ""; self.price = 0; }
}
```

Validation is a plain function that returns "" when the input is good, or the
error text otherwise. There is no validator trait to implement and no framework
to register it with; the handler calls it.

```kyte
// Features/Products/CreateProduct/validator.ky
pub fn validateCreateProduct(cmd: CreateProduct): string {
    if (cmd.name.length == 0) { return "name is required"; }
    if (cmd.price < 0) { return "price must be >= 0"; }
    return "";
}
```

The handler binds the command, validates it, does the work, and returns the new
product's card. Because this is hypermedia, the 201 body is the HTML fragment
the browser swaps in; for a JSON API you would `serde.json.stringify` a DTO
instead.

```kyte
// Features/Products/CreateProduct/handler.ky
pub struct CreateProductHandler impl RouteHandler {
    repo: ProductRepository,
    init(repo: ProductRepository) { self.repo = repo; }

    async fn serve(self: CreateProductHandler, ctx: Context): Response {
        let cmd = ctx.bind<CreateProduct>();
        let err = validateCreateProduct(cmd);
        if (err.length != 0) {
            return response.Response(Status.BadRequest, err);
        }
        let _ = await self.repo.create(cmd.name, cmd.price);
        let html = productCard(cmd.name, cmd.price);
        return response.Response(Status.Created, html)
            .setHeader("Content-Type", "text/html; charset=utf-8");
    }
}
```

## Wiring: routes and the composition root

Each feature owns a small `routes.ky` that binds its paths to handler
instances. `app.get`/`app.post`/`app.put`/`app.delete`/`app.patch` each take a
path and a handler INSTANCE, and you pass that handler its dependencies as plain
constructor arguments.

```kyte
// Features/Products/routes.ky
pub fn registerProducts(app: App, repo: ProductRepository): void {
    app.post("/api/products", CreateProductHandler(repo));
    app.get("/api/products/{id:int}", GetProductByIdHandler(repo));
}
```

`{id:int}` is a typed path parameter: a non-numeric id never reaches the
handler, it is a 400 at the router. Plain `{name}` captures any single segment.

`main.ky` is the composition root. It builds the shared dependencies ONCE and
calls each feature's `register`. There is no container resolving things behind
your back: you can see every dependency being constructed.

```kyte
// main.ky
import web.app;
import Features.Products.Shared.database;
import Features.Products.Shared.repository;
import Features.Products.routes;

fn buildApp(): App {
    let app = App();
    let conn = InMemoryConnection();
    let repo = ProductRepository(conn);
    registerProducts(app, repo);
    app.useStatic("/", "./wwwroot");
    return app;
}

fn main(): void {
    let app = buildApp();
    // The port is read from app.yaml (config.port) via app.config, or --port if the orchestrator passed
    // one, else the default. See Chapter 18 for the config API; app config is file-based, not env vars.
    let port = app.config.port(8080);
    console.log("Listening on http://127.0.0.1:" + `${port}`);
    app.run(port);
}
```

As the app grows you add a feature folder with its own `register(app, deps...)`
and one call here. That is the whole scaling story for structure.

## The data-access layer

The repository is the one place that knows SQL. Its connection field is the
`Connection` **trait** from `data.db`, not a concrete database type, so the same
repository runs over an in-memory connection in tests and over a real database
in production with no change.

```kyte
// Features/Products/Shared/repository.ky
pub struct ProductRepository {
    conn: Connection,
    init(conn: Connection) { self.conn = conn; }

    pub async fn findById(self: ProductRepository, id: int): ProductDto | undefined {
        let params = List<DbValue>();
        params.push(db.dbInt(id));
        let rs = await self.conn.query("SELECT id, name, price FROM products WHERE id = $1", params);
        return orm.bindOne<ProductDto>(rs);
    }

    pub async fn create(self: ProductRepository, name: string, price: int): int {
        let params = List<DbValue>();
        params.push(db.dbText(name));
        params.push(db.dbLong(price));
        let r = await self.conn.exec("INSERT INTO products (name, price) VALUES ($1, $2)", params);
        return r.rows_affected as int;
    }
}
```

The starter ships a tiny `InMemoryConnection impl Connection` (in
`Shared/database.ky`) so the app runs and its tests pass with no database
server. Parameters are built with `db.dbInt`/`db.dbText`/`db.dbLong` and bound
to `$1, $2, ...`; the micro-ORM (`orm.bindOne`/`orm.bindAll`) maps result rows
onto `ProductDto` by column name. Chapter 18, Data access and the ORM, covers
the data-access layer, the `Repository<T>` helper, and connection strings in full.

## Testing offline

Handlers are objects, so a test builds the app the same way the composition
root does and drives one request through `app.dispatch(req)` with no socket
open. That makes feature tests fast and hermetic.

```kyte
// tests/features/products_test.ky
fn testApp(): App {
    let conn = InMemoryConnection();
    let repo = ProductRepository(conn);
    let app = App();
    app.post("/api/products", CreateProductHandler(repo));
    app.get("/api/products/{id:int}", GetProductByIdHandler(repo));
    return app;
}

@test
fn test_get_missing_is_404(): void {
    let app = testApp();
    let req = Request.fromString("GET /api/products/999 HTTP/1.1\r\nHost: x\r\n\r\n");
    let res = app.dispatch(req);
    assert.equalInt(res.status.toCode(), 404);
}
```

```bash
kyte test tests/features/products_test.ky
```

## The same app over a real database

The example includes `main_postgres.ky` at the project root: the SAME app over a
real PostgreSQL. Look at it beside `src/main.ky` and only the composition root
differs. Every feature slice, the repository, the handlers, and the views are
identical, because they depend on the `Connection` trait, never on a driver.

```kyte
// main_postgres.ky  (excerpt)
fn buildApp(dsn: string, poolSize: int): App {
    let app = App();
    let conn = PooledConnection(dsn, poolSize);   // built now; connects lazily, per request
    let repo = ProductRepository(conn);
    registerProducts(app, repo);
    app.useStatic("/", "./wwwroot");
    return app;
}
```

`PooledConnection` (in `Shared/pooled_connection.ky`) wraps a
`pool.Pool(PgDriver(), dsn, size)` and implements `Connection` by acquiring a
connection per call, running the statement, and releasing it. The pool is built
synchronously and opens its connections lazily inside a request, which is the
pattern to reach for: opening a connection is asynchronous, and you cannot drive
an asynchronous call to completion from the synchronous `main` before the event
loop starts. Chapters 18 and 20 build this out with the ORM and the concrete
drivers; the [`run-live.sh`](examples/run-live.sh) script runs the whole thing
against a real PostgreSQL and then behind the orchestrator.

## What else the app gives you

The framework in `web.*` covers the rest of a real application:

- **Server-sent events** for live updates: `app.sse(path, handler)` and an
  `EventBus` push HTML fragments to connected browsers (see `web.sse`).
- **WebSockets** for a bidirectional channel: `app.ws(path, handler)` upgrades a
  connection so the client can talk back in real time (see the section below).
- **Sessions and cookies**: `web.session` and `web.cookie` for signed,
  server-side sessions and cookie handling.
- **Middleware**: `app.use(mw)` runs cross-cutting logic (a `RouteMiddleware`)
  around every handler, and the library ships CORS, CSRF, rate limiting, a
  request-id tagger, secure headers, and a body-size limit.
- **Static files**: `app.useStatic(prefix, dir)`, as above.
- **The client side**: `web.client` is an HTTP client for calling other
  services, and TLS is built in (chapter 15 and the runtime crypto are pure
  Kyte, no OpenSSL).

## Real-time: server-sent events and WebSockets

Two edges push work past the finite request and response cycle, and they are for
different jobs.

**Server-sent events (SSE)** are the default for hypermedia. The server holds one
long-lived response open and streams HTML fragments (or Datastar patches) to the
browser as things change. It is one-directional, server to client, which is exactly
what a live UI needs most of the time. Register one with `app.sse(path, handler)`
and push through an `EventBus`. Datastar (chapter 21) builds on this.

**WebSockets** are for the cases SSE cannot cover: a genuinely bidirectional,
low-latency channel where the client also talks back in real time, collaborative
editing, a terminal, presence and typing indicators, multiplayer. Reach for a
WebSocket only when you actually need the client to send as well as receive; if you
just need live updates on the page, SSE is simpler and is the right default.

A WebSocket route is a handler that owns a receive loop for the life of the
connection. Register it with `app.ws(path, handler)`:

```kyte
import web.app;
import web.websocket;
import web.request;

// Echoes every message back to the sender.
class Echo impl WsHandler {
    pub async fn serve(self: Echo, ws: websocket.WebSocket, req: request.Request): void {
        // `req` is the upgrade request, so read cookies / session here for auth
        // BEFORE the loop, exactly like a normal route.
        while (ws.isOpen()) {
            let m = await ws.recv();          // blocks for the next message
            if (m == undefined) { break; }    // the peer closed
            if (m.isText) {
                let _ = await ws.sendText(m.text);
            } else {
                let _ = await ws.sendBinary(m.data, m.len);
            }
        }
    }
}

fn main(): int {
    let server = app.App();
    server.ws("/echo", Echo());
    server.run(8080);
    return 0;
}
```

`recv` returns a `Message` (`isText` selects `text` for a text frame, or the raw
bytes at `data` for `len` bytes on a binary frame) or `undefined` once the peer
closes. Ping and pong frames and the close handshake are handled for you and never
surface as messages. Send with `ws.sendText(s)` / `ws.sendBinary(buf, len)`, and end
the connection with `ws.close(code, reason)`.

On the browser side this is the standard `WebSocket` API:

```javascript
const ws = new WebSocket("ws://localhost:8080/echo");
ws.onopen = () => ws.send("hello");
ws.onmessage = (e) => console.log("echo:", e.data);
```

**Restrict the origin.** A browser sends an `Origin` header on the upgrade, and
because cookie-based CSRF tokens do not apply to WebSockets, checking it is the
equivalent guard. By default any origin is accepted (handy in development); call
`wsAllowOrigin` once per allowed origin to lock it down. A disallowed browser origin
is refused with `403` before the upgrade; a request with no `Origin` (a non-browser
client) is allowed, since there is nothing to forge.

```kyte
server.ws("/echo", Echo());
server.wsAllowOrigin("https://app.example.com");
```

**Broadcasting to many clients.** One handler instance serves every connection, so
it can hold shared state, a "hub" of the connected sockets, and fan a message out to
all of them. Each `serve` adds its socket to the hub; a message from one is written
to every live socket (closed ones are dropped):

```kyte
class Hub {
    pub conns: list.List<websocket.WebSocket>,
    init() { self.conns = list.List<websocket.WebSocket>(); }
    fn add(self: Hub, ws: websocket.WebSocket): void { self.conns.push(ws); }
    async fn broadcast(self: Hub, text: string): void {
        let alive = list.List<websocket.WebSocket>();
        let i = 0;
        while (i < self.conns.size()) {
            let c = self.conns.get(i);
            if (c != undefined && c.isOpen()) {
                let _ = await c.sendText(text);
                alive.push(c);
            }
            i = i + 1;
        }
        self.conns = alive;    // compact: drop connections that have closed
    }
}

class Chat impl WsHandler {
    pub hub: Hub,
    init(h: Hub) { self.hub = h; }
    pub async fn serve(self: Chat, ws: websocket.WebSocket, req: request.Request): void {
        self.hub.add(ws);
        while (ws.isOpen()) {
            let m = await ws.recv();
            if (m == undefined) { break; }
            if (m.isText) { await self.hub.broadcast(m.text); }
        }
    }
}

// server.ws("/chat", Chat(Hub()));
```

Because the app is a single reactor, the hub needs no locking: handlers cooperate,
never preempt. To scale past one instance you would move the fan-out to a shared bus
(each instance subscribes and rebroadcasts to its own connections), the same shape as
the SSE `EventBus`.

A note on deployment, the same one that applies to SSE: a WebSocket is long-lived
and holds one reactor slot for its lifetime, and a web app is a single reactor, so
you scale by running instances behind the orchestrator's proxy (chapter 23). The
proxy passes the `Upgrade` through and keeps each connection pinned to the instance
that accepted it.

## Hypermedia responses: fragments, redirects, and control headers

A hypermedia handler returns a small HTML fragment that the client library swaps into
the page. Two `Response` helpers make that intent explicit and set the right headers for
you:

```kyte
// A partial for a swap: 200 with text/html and `Vary: HX-Request` (so a shared cache
// never serves a fragment where a full page is expected).
return response.Response.fragment(myView(row));

// A full page for a first load or hard navigation.
return response.Response.page(shell(myView(row)));
```

For the Post/Redirect/Get flow, `Response.redirect(url)` (and `seeOther`) build a
`303 See Other`, and `redirectWith(url, status)` lets you pick a different `3xx`.

Because the five scaffolded client libraries drive the server differently (htmx reads
`HX-*` response headers, unpoly reads `X-Up-*`, alpine-ajax reads `X-Alpine-*`, datastar
streams over SSE, htmz just loads a document), the `web.hyper` module lets a handler
express control intent once and emits the right mechanism for whichever library made the
request, detected from its headers:

```kyte
import web.hyper;

// htmx gets a full-page HX-Redirect; unpoly, alpine, htmz, and a plain browser follow a 303.
fn onSaved(ctx: Context): Response {
    // ... perform the write ...
    return hyper.redirect(ctx.request, "/orders");
}

// Fire a client event, retarget, or reswap on the way out.
fn onError(ctx: Context): Response {
    let res = response.Response.fragment(errorView(msg));
    hyper.retarget(res, ctx.request, "#form-errors");
    hyper.trigger(res, ctx.request, "form-invalid");
    return res;
}
```

`ctx.isHypermedia()` and `ctx.wantsFragment()` tell you whether the request came from a
hypermedia client (so the same route can return a bare fragment to htmx and a full page
to a fresh browser), and `ctx.framework()` names the library. datastar apps drive control
through the `kyte-datastar` package's SSE helpers rather than these headers, but are still
recognised by `isHypermedia`.

For cookies that carry a session or auth token, use `Response.setCookieFull(cookie)` rather
than the simple `setCookie(name, value)`: it renders the full `web.cookie.Cookie` with
`HttpOnly`, `Secure`, `SameSite`, and `Max-Age`, whereas `setCookie` only ever writes a
bare `Path=/`.

### One route, page or fragment

`hyper.render` picks the shape for you: it returns the bare fragment to a hypermedia client
and the full page (the fragment wrapped by a `shell` function) to a hard navigation, and sets
`Vary: HX-Request` on both:

```kyte
fn products(ctx: Context): Response {
    return hyper.render(ctx.request, layout, productList(rows));   // layout: (string) -> string
}
```

### Out-of-band updates and dynamic attributes

To update a second region in the same response (a cart badge alongside a list row), give that
element an id and the out-of-band marker for the active library via `hyper.oobAttr`. It plugs
into a KYX element as a bare `{expr}` attribute (an expression that yields a whole attribute):

```kyte
<div id="cart-badge" {hyper.oobAttr(ctx.request)}>Cart ({count})</div>
```

The same bare-attribute form carries conditional attributes, and `hyper.classList` composes a
class string from conditional pieces (empties dropped):

```kyte
<button {isBusy ? "disabled" : ""} class={hyper.classList(cls)}>Save</button>
```

### Forms: CSRF and validation

`web.forms` bridges the form pieces into KYX. `csrfField(ctx)` renders the hidden `_csrf` input
that `web.csrf` checks, and `fieldError`/`hasError` render a `ValidationResult` inline so an
invalid submit re-renders as a fragment with messages beside each field:

```kyte
<form data-on:submit="@post('/register')">
    {forms.csrfField(ctx)}
    <input name="email" value={cmd.email} />
    {forms.fieldError(result, "email")}
    <button>Register</button>
</form>
```

### Typed URLs and server push

`web.urls.build(pattern, params)` builds the URLs that live in `hx-get`/`data-on` attributes,
substituting `:name`/`{name}` path parameters and appending the rest as a query string, so a
route rename does not silently break a hand-written URL. And `web.sse.htmxFrame(event, fragment)`
builds one Server-Sent Events frame for the htmx SSE extension (the counterpart to datastar's
patch helper) when you push updates over `app.sse`.

### Unpoly

Unpoly is the scaffold you get with `kyte init web --name shop -f unpoly`. It drives the page from
`up-*` attributes in the markup: a link or form marked `[up-target]` is fetched over AJAX, and
Unpoly swaps the matching fragment from the response into the current page. The server side is the
same fragment-returning code you have already seen; only the client attributes differ.

```kyte
// A slice rendered for Unpoly. The link fetches /products and Unpoly swaps the
// .catalog fragment; the form submits and Unpoly re-renders #cart.
fn catalog(ctx: Context): Response {
    return hyper.render(ctx.request, layout, <div class="catalog">
        <a href="/products" up-target=".catalog">Refresh</a>
        <form action="/cart/add" method="post" up-target="#cart" up-submit>
            {forms.csrfField(ctx)}
            <button>Add to cart</button>
        </form>
        <div id="cart">Cart ({count})</div>
    </div>);
}
```

Unpoly reads `X-Up-*` response headers, and `web.hyper` sets them for you. `hyper.redirect` returns a
`303 See Other` with `X-Up-Location` so Unpoly updates the address bar after a Post/Redirect/Get,
`hyper.trigger` emits `X-Up-Events`, and out-of-band regions use the Unpoly form of `hyper.oobAttr`.
Because Unpoly sends `X-Up-Target` and `X-Up-Version` on every fragment request, `ctx.isHypermedia()`
is true and `ctx.framework()` reports Unpoly, so a route can serve a bare fragment to Unpoly and a
full page to a fresh browser from the same handler.

### Alpine AJAX

Alpine is the scaffold from `kyte init web --name shop -f alpine`: Alpine.js with its AJAX plugin.
Behaviour is sprinkled into markup with `x-` attributes. A link or form marked `x-target="ids"`
submits over AJAX, and the plugin replaces each listed element id with the element of the same id
found in the response. So the server returns a fragment whose element ids line up with the targets.

```kyte
// A slice rendered for Alpine. The form posts over AJAX and replaces #cart and
// #flash with the same ids from the response fragment.
fn catalog(ctx: Context): Response {
    return hyper.render(ctx.request, layout, <div x-data>
        <form action="/cart/add" method="post" x-target="cart flash">
            {forms.csrfField(ctx)}
            <button>Add to cart</button>
        </form>
        <div id="cart">Cart ({count})</div>
        <div id="flash"></div>
    </div>);
}
```

Alpine AJAX does not use a redirect header: it follows a standard `3xx` response transparently, so
`hyper.redirect` returns a plain `303` for it (there is no `X-Alpine-Redirect`; only htmx takes the
`HX-Redirect` path). Alpine sends `X-Alpine-Request: true` and `X-Alpine-Target` on its requests, so
`ctx.isHypermedia()` and `ctx.wantsFragment()` are true and `ctx.framework()` reports Alpine. This is
why expressing control intent through `web.hyper` rather than hand-writing headers pays off: the same
handler serves htmx, Unpoly, Alpine, htmz, and a plain browser correctly, each by its own mechanism.

## Where to go next

- **Chapter 18, Data access and the ORM**, takes the `Connection` interface further:
  `DbValue`, the micro-ORM, the generic `Repository<T>`, connection strings, and
  backing this app with PostgreSQL.
- **Chapter 19, Package management**, explains `project.json` and how the
  compiler resolves a driver dependency.
- **Chapter 21, Datastar: server-driven hypermedia**, drives the browser over a
  live SSE connection: patch elements and reactive signals from the server.
- **Chapter 20, Database drivers**, introduces each driver (PostgreSQL, MySQL,
  SQL Server, MongoDB) and how to add it to a project.
- **Chapter 23, Deploying with the orchestrator**, runs replicas of this app
  behind a load balancer.
