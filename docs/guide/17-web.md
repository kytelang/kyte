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
    // one, else the default. See Chapter 18 for the config interface; app config is file-based, not env vars.
    let port = app.config.port(8080);
    console.log("Listening on http://127.0.0.1:" + `${port}`);
    app.run(port);
}
```

As the app grows you add a feature folder with its own `register(app, deps...)`
and one call here. That is the whole scaling story for structure.

## The data-access interface

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
the `Connection` interface, the `Repository<T>` helper, and connection strings in full.

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
- **Sessions and cookies**: `web.session` and `web.cookie` for signed,
  server-side sessions and cookie handling.
- **Middleware**: `app.use(mw)` runs cross-cutting logic around every handler.
  See the dedicated [Middleware](#middleware) section below.
- **Static files**: `app.useStatic(prefix, dir)`, as above.
- **The client side**: `web.client` is an HTTP client for calling other
  services, and TLS is built in (chapter 15 and the runtime crypto are pure
  Kyte, no OpenSSL).

## Middleware

Middleware is cross-cutting request/response logic that wraps every route
handler: authentication, CORS, CSRF, logging, response tagging. You register it
with `app.use(mw)`, and each middleware implements the `RouteMiddleware` trait
from `web.routing`:

```kyte
pub trait RouteMiddleware {
    async fn handle(self: RouteMiddleware, ctx: Context, next: Chain): Response;
}
```

`handle` receives the request `ctx` and a `Chain` called `next`. It does whatever
it needs, then calls `next.proceed(ctx)` to run the rest of the chain (the next
middleware, or finally the route handler) and gets back a `Response` it may
inspect or edit. To **short-circuit**, it returns its own `Response` without
calling `next` at all: the handler and everything after this middleware never
run.

### Ordering and short-circuit

Middlewares run in **registration order**, nested around the handler like layers
of an onion. The first one registered is the outermost. So with

```kyte
app.use(Tag("outer"));
app.use(Tag("inner"));
app.get("/hit", Handler());
```

a request flows `outer -> inner -> handler`, and the responses unwind
`handler -> inner -> outer`. A middleware that appends to the body after
`next.proceed` therefore sees the inner tag applied first:

```kyte
// Appends a label AFTER the downstream runs (post-processing + ordering).
struct Tag impl RouteMiddleware {
    label: string,
    init(label: string) { self.label = label; }
    async fn handle(self: Tag, ctx: routing.Context, next: routing.Chain): Response {
        let resp = await next.proceed(ctx);
        resp.body = resp.body + "[" + self.label + "]";
        return resp;
    }
}
// GET /hit -> body "handler[inner][outer]"
```

An auth guard is the short-circuit case: it returns `401` and never calls `next`,
so the handler is skipped entirely:

```kyte
// Rejects with 401 when the `x-auth` header is absent; never calls next.
struct Guard impl RouteMiddleware {
    init() {}
    async fn handle(self: Guard, ctx: routing.Context, next: routing.Chain): Response {
        if (ctx.request.getHeader("x-auth") == undefined) {
            return response.Response(Status.Unauthorized, "denied");
        }
        return await next.proceed(ctx);   // header present: fall through to the handler
    }
}

app.use(Guard());
```

### The built-in middleware and helpers

Two of the built-ins are `RouteMiddleware` you register with `app.use`:

- **CORS** (`web.cors`). Configure a policy and register it; it sets the
  `Access-Control-*` headers and answers `OPTIONS` preflight requests directly.

  ```kyte
  import web.cors;
  let policy = cors.CorsConfig {
      allowOrigin: "https://app.example.com", allowOrigins: list.List(),
      allowMethods: "GET, POST, PUT, DELETE, OPTIONS", allowHeaders: "Content-Type",
      maxAge: "600", allowCredentials: true,
  };
  app.use(cors.CorsMiddleware(policy));
  ```

- **CSRF** (`web.csrf`). Enforces the double-submit token pattern: safe methods
  (GET/HEAD/OPTIONS) pass and receive the token, unsafe methods must echo it
  back. It expects a session layer upstream to have placed the expected token.

  ```kyte
  import web.csrf;
  app.use(csrf.CsrfMiddleware());
  ```

The other four are helper modules you call from inside a handler rather than
register globally:

- **Sessions** (`web.session`). A `SessionStore` creates and looks up
  server-side sessions keyed by an opaque id you carry in a cookie.

  ```kyte
  import web.session;
  let store = session.SessionStore();
  let s = store.createSession();          // fresh session with a new id
  // ... later, on a subsequent request ...
  let again = store.getSession(s.id);     // rehydrate by id
  ```

- **Cookies** (`web.cookie`). Build a `Cookie` and render it into a `Set-Cookie`
  header value.

  ```kyte
  import web.cookie;
  let c = cookie.Cookie {
      name: "sid", value: s.id, path: "/", domain: "",
      maxAge: 3600, secure: true, httpOnly: true, sameSite: "Lax",
  };
  ctx.response.header("Set-Cookie", cookie.serialize(c));
  ```

- **Validation** (`web.validation`). Accumulate field checks with a fluent
  `Rules` builder and seal them into a `ValidationResult`.

  ```kyte
  import web.validation as v;
  let result = v.Rules()
      .check(v.notEmpty(name), "name", "name is required")
      .check(v.between(qty, 1, 99), "qty", "qty must be 1..99")
      .result();
  if (!result.valid) { /* return a 400 with result.errors */ }
  ```

- **Redaction** (`web.redact`). Mask sensitive header values before logging, so
  an `Authorization` or `Cookie` header never reaches a log line in the clear.

  ```kyte
  import web.redact;
  if (redact.isSensitiveHeader(name)) { value = redact.redactHeaderValue(name, value); }
  ```

The middleware chain shape is pinned by conformance cases `440_middleware_chain`
(ordering and short-circuit) and `172_web_middleware_modules_compile` (the
built-ins compile and wire).

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
