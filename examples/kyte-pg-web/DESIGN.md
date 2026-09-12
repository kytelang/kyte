# Kyte Sandwich Shop: Design

An online sandwich shop built on the Kyte platform. It exists to demonstrate the
whole platform working together, end to end: the language and its web framework,
the PostgreSQL driver and the micro-ORM over the common `db` seam, the
nova-datastar package for hypermedia and Server-Sent Events, and the orchestrator
for a multi-replica, zero-downtime deployment with its control-plane state on
NovaDB.

This document is the authoritative specification. Code is written to follow it,
not the other way round.

## 1. What the shop demonstrates

| Platform pillar | How the shop exercises it |
| --- | --- |
| Language and web framework | Vertical-slice features, DI, the mediator, typed request binding |
| PostgreSQL driver and `db` seam | All shop data (catalogue, cart, orders, users) over the driver, with a real transaction on checkout |
| Micro-ORM | `bindAll`/`query<T>` from rows to `@serializable` DTOs, `$N` bound parameters |
| nova-datastar | Every reactive interaction: add-to-cart, live cart totals, live order status, all as SSE patches, with `.nsx` views carrying the `data-*` attributes |
| SSE streaming seam | `app.sse` route takeover plus the `web.sse` `EventBus`, feeding nova-datastar patches to the browser |
| Orchestrator | Deployed as N replicas behind `service`, supervised by `orchd`, config store on NovaDB, rolling deploy, in fd-handoff mode |

NovaDB is not the application store here (the application store is PostgreSQL by
decision), but it is exercised in its natural platform role as the orchestrator's
config and leader-lease store.

## 2. Conventions (mandatory)

These are hard rules. The current code violates some of them and is refactored to
comply (see section 14).

1. **No inline HTML in handlers or stores.** Every fragment of markup lives in an
   `.nsx` view under a feature's `views/` folder. Handlers call a view function
   and return its string. A handler that concatenates HTML is a defect.
2. **nova-datastar for all reactivity.** Reactive attributes (`data-on-click`,
   `data-signals`, `data-bind`, `data-indicator`, and so on) are written in
   `.nsx`. SSE responses are produced with the nova-datastar `Sse` verbs
   (`patchElements`, `patchSignals`, `removeElement`), never by hand-writing
   `event:`/`data:` lines in application code.
3. **The schema is the one in section 4.** UUID primary keys, the modifier and
   order tables, and the money and timestamp types are as specified. Entities and
   SQL align to it.
4. **Vertical slices.** One folder per use case under `Features/<Area>/<UseCase>/`
   with a `command.ky` or `query.ky` (the request type) and a `handler.ky`.
   Shared data access sits in a repository under `Features/<Area>/Shared/` or in
   `Shared/` when cross-area. Domain DTOs live under `Domain/`.
5. **DI by type name.** A dependency is a constructor parameter; the framework
   injects `require("<TypeName>")`, so the registration key is the type name.
6. **Money is exact.** `DECIMAL(10,2)` in the database. Arithmetic on money
   (line subtotals, order totals, tax) happens in SQL, not by pulling values into
   `double` and back. DTOs may read money as `decimal` for display.
7. **Escaping.** `{expr}` in `.nsx` auto-escapes. Any value that is itself
   pre-rendered markup is composed as a view function, never interpolated raw
   from user input.

## 3. Architecture overview

```
Browser (Datastar) ──HTTP/SSE──> service (LB, fd-handoff) ──fd──> shop replica
                                                                     │
                     app.sse "/…/events"  ◄── web.sse EventBus ──────┤
                                                                     │
   Features (slices) ──> Repositories ──> db seam ──> PgDriver ──> PostgreSQL
                                                                     │
   orchd (control plane) ──> config + leader lease ──> NovaDB
```

- The **shop replica** is one Kyte `web.app` process. Under the orchestrator many
  replicas run, each receiving client sockets over fd-handoff from `service`.
- **Reactivity** is Datastar over SSE. A mutation on one connection publishes to
  the `EventBus`; the `app.sse` handler on the customer's connection turns that
  into a nova-datastar patch.
- **Application data** is PostgreSQL through the `db` seam. **Orchestrator state**
  is NovaDB.

## 4. Database schema

PostgreSQL, `gen_random_uuid()` primary keys, `timestamptz`, exact `DECIMAL`.
This follows the shared schema. Two deliberate, documented additions are noted.

```sql
-- Users (customers and admins)
CREATE TABLE users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email TEXT UNIQUE NOT NULL,
    password_hash TEXT NOT NULL,
    full_name TEXT NOT NULL,
    phone TEXT,
    address TEXT,
    role TEXT NOT NULL DEFAULT 'customer' CHECK (role IN ('customer','admin')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE categories (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT UNIQUE NOT NULL,
    description TEXT,
    sort_order INT NOT NULL DEFAULT 0
);

CREATE TABLE products (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    category_id UUID REFERENCES categories(id) ON DELETE SET NULL,
    name TEXT NOT NULL,
    description TEXT,
    price DECIMAL(10,2) NOT NULL CHECK (price >= 0),
    image_url TEXT,
    is_available BOOLEAN NOT NULL DEFAULT true,
    is_vegetarian BOOLEAN NOT NULL DEFAULT false,  -- ADDITION: supports the vegetarian filter independent of category
    stock_quantity INT NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE modifiers (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL,                 -- e.g. "Bread", "Cheese"
    options JSONB NOT NULL,             -- e.g. ["White","Whole Wheat"]
    extra_cost DECIMAL(10,2) NOT NULL DEFAULT 0.00
);

CREATE TABLE product_modifiers (
    product_id UUID REFERENCES products(id) ON DELETE CASCADE,
    modifier_id UUID REFERENCES modifiers(id) ON DELETE CASCADE,
    is_required BOOLEAN NOT NULL DEFAULT false,
    max_choices INT NOT NULL DEFAULT 1,
    PRIMARY KEY (product_id, modifier_id)
);

CREATE TABLE orders (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES users(id) ON DELETE SET NULL,
    order_number TEXT UNIQUE NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending','paid','preparing','ready','delivered','picked_up','cancelled')),
    subtotal DECIMAL(10,2) NOT NULL DEFAULT 0.00,
    tax DECIMAL(10,2) NOT NULL DEFAULT 0.00,
    total_amount DECIMAL(10,2) NOT NULL DEFAULT 0.00,
    delivery_type TEXT NOT NULL DEFAULT 'pickup' CHECK (delivery_type IN ('pickup','delivery')),
    delivery_address TEXT,
    payment_method TEXT NOT NULL DEFAULT 'mock',
    payment_id TEXT,
    notes TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE order_items (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    order_id UUID REFERENCES orders(id) ON DELETE CASCADE,
    product_id UUID REFERENCES products(id) ON DELETE SET NULL,
    product_name TEXT NOT NULL,        -- snapshot of the product name at order time
    unit_price DECIMAL(10,2) NOT NULL, -- snapshot of the unit price (incl. modifier cost)
    quantity INT NOT NULL CHECK (quantity > 0),
    modifiers JSONB NOT NULL DEFAULT '{}',  -- selected modifier options snapshot
    subtotal DECIMAL(10,2) GENERATED ALWAYS AS (unit_price * quantity) STORED
);

-- Optional (kept from the shared schema, used by the admin inventory screen)
CREATE TABLE ingredients (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL,
    quantity_on_hand DECIMAL(10,2) NOT NULL DEFAULT 0,
    unit TEXT CHECK (unit IN ('kg','g','l','ml','pcs'))
);

CREATE TABLE product_ingredients (
    product_id UUID REFERENCES products(id) ON DELETE CASCADE,
    ingredient_id UUID REFERENCES ingredients(id) ON DELETE CASCADE,
    quantity_required DECIMAL(10,2) NOT NULL,
    PRIMARY KEY (product_id, ingredient_id)
);
```

Notes on the two additions:

- `products.is_vegetarian` is added so the vegetarian filter works as a product
  attribute (the shared spec lists both a "Vegetarian" category and a vegetarian
  filter; the filter needs an attribute). This is the only column added to the
  shared product table.
- `orders.subtotal` is added alongside `total_amount` so tax can be shown as a
  separate line; `order_items.subtotal` stays a generated column as in the shared
  schema.

Files: `schema.sql` (DDL) and `seed.sql` (categories, products, modifiers,
`product_modifiers`, one admin user). The stdlib migrations runner
(`data.migrate`) can also apply this; the run scripts use `schema.sql` for
clarity.

## 5. Domain entities (read models)

`@serializable` DTOs whose fields match query column aliases (case-insensitive).
UUIDs are read as `str.Str` (zero-copy text). Money is read as `decimal` for
display. One DTO per read shape, under `Domain/entities/`.

- `catalog.ky`: `CategoryView { id, name, description, productCount }`,
  `ProductView { id, name, description, price, imageUrl, isVegetarian, isAvailable }`,
  `ProductDetail { ... + stockQuantity }`, `ModifierView { id, name, options, extraCost, isRequired, maxChoices }`.
- `cart.ky`: `CartLineView { productId, name, unitPrice, quantity, modifiersLabel, lineTotal }`,
  `CartSummary { itemCount, subtotal, tax, total }`.
- `orders.ky`: `OrderView { id, orderNumber, status, total, createdAt }`,
  `OrderDetail { ... + subtotal, tax, deliveryType, items }`,
  `OrderItemView { productName, unitPrice, quantity, modifiersLabel, subtotal }`.
- `admin.ky`: `DashboardStats { newOrders, revenueToday, lowStock }`,
  `IngredientView { id, name, quantityOnHand, unit }`.
- `user.ky`: `UserView { id, email, fullName, role }`.

## 6. Data access

One repository per aggregate, each `impl Service`, each holding the shared
connection pool. A single `Db` service owns the `pool.Pool`; repositories take it
by constructor injection, so all repositories share one pool.

- `Shared/Db.ky`: `Db impl Service` wrapping `pool.Pool(PgDriver(), dsn, size)`,
  exposing `acquire()`/`release()` and a `withTransaction` helper.
- `Features/Catalog/Shared/CatalogRepository.ky`: category and product reads,
  product detail, modifiers for a product, filters (category, vegetarian, price,
  search).
- `Features/Cart/Shared/CartRepository.ky`: the server-side cart (section 7).
- `Features/Orders/Shared/OrderRepository.ky`: create order (transaction),
  read order and items, advance status, list a user's orders.
- `Features/Admin/Shared/AdminRepository.ky`: dashboard stats, product CRUD,
  order management, inventory.

Transactions use `conn.begin()` / `conn.commit()` / `conn.rollback()` from the
`db` seam. Parameters are `DbValue` on `$N` placeholders. Money maths stays in
SQL (see convention 6). UUID parameters use `db.dbUuid`.

## 7. Cart

The cart is server-side, keyed by a `cart_id` cookie (a random token set on first
add). This keeps the cart working before a user logs in and demonstrates cookies
and sessions without requiring auth for browsing.

Storage: a `cart_items` table (or a `carts` + `cart_items` pair) keyed by
`cart_id`, holding `product_id`, `quantity`, and the selected `modifiers` JSON.
Line unit price is the product price plus the sum of chosen modifier
`extra_cost`. Cart totals (subtotal, tax at a fixed rate, total) are computed in
SQL.

Operations (each a slice): `AddToCart`, `UpdateCartItem`, `RemoveCartItem`,
`GetCart`. Each returns the cart fragment view; the add-to-cart button and the
cart badge update live via Datastar (section 9).

On checkout the cart is copied into `orders` + `order_items` (with product name
and unit price snapshotted) inside one transaction, then cleared.

## 8. Checkout and the order lifecycle

`Checkout` slice: collects name, email, delivery type, address (for delivery),
and payment method. Payment is a **mock**: a `PayWithMock` step that always
succeeds and records a fake `payment_id`. Real card entry is out of scope by
policy.

`PlaceOrder` (the transaction):

1. `begin`
2. insert `orders` (status `pending`), `RETURNING id`
3. `INSERT INTO order_items SELECT ...` from the cart rows, snapshotting name and
   unit price, computing per-line values in SQL
4. update `orders` subtotal, tax, total from the item sum; set a human-readable
   `order_number` (for example `S-2026-000123`)
5. clear the cart
6. `commit`

Order status pipeline: `pending → paid → preparing → ready → (delivered | picked_up)`,
plus `cancelled`. `AdvanceStatus` (admin/kitchen) moves an order one step with a
single atomic SQL statement and publishes the change (section 9).
`OrderConfirmation` shows the order number and opens the live-status stream.
`OrderHistory` lists a logged-in user's orders with a reorder action.

## 9. Reactivity: nova-datastar over the SSE seam

Two layers, cleanly separated:

- **Views** are `.nsx` and carry Datastar attributes. Example: an add button is
  `<button data-on-click="@post('/cart/add?product={id}')" data-indicator="adding">Add</button>`.
  A page that shows live order status contains
  `<div id="order-status" data-on-load="@get('/orders/{id}/events')">…</div>`.
- **SSE responses** are produced with the nova-datastar `Sse` verbs. A handler
  never writes `event:`/`data:` lines by hand.

Flow for a reactive mutation (add-to-cart):

1. `data-on-click="@post('/cart/add?product=…')"` sends the request.
2. The `AddToCart` handler updates the cart, then returns the re-rendered cart
   badge and cart panel fragments (an `.nsx` view). For an immediate response
   this can be a normal `Response`; for cross-connection updates it publishes to
   the `EventBus`.

Flow for live order status (cross-actor):

1. The confirmation and history pages open `@get('/orders/{id}/events')`.
2. That route is registered with `app.sse`. Its handler wraps the connection in
   nova-datastar's `Sse`, subscribes to the `EventBus` topic `order:<id>`, seeds
   the current status, then forwards each published change as
   `sse.patchElements(fragment, PatchElementOptions.inner("#order-status"))`.
3. When the kitchen calls `AdvanceStatus`, that handler updates the DB and
   publishes the newly rendered `.nsx` status fragment to `order:<id>`. Every
   watching browser is patched with no reload.

Required small change to nova-datastar: `Sse.overStream` currently takes the
concrete `aio.AsyncStream`. The `app.sse` handler receives the `aio.AsyncIO`
trait (so it also works over TLS). Add `Sse.overStreamIO(io: aio.AsyncIO)` (or
change `overStream` to accept the trait); the sink already only needs `sendStr`.
This is the one framework-level change the shop requires and it is generally
useful.

Multi-replica note: the in-process `EventBus` fans out within one replica only.
Under the orchestrator (section 12), a status change on replica A must reach a
customer pinned to replica B, so the bus transport is swapped, behind the same
interface, for a shared backbone. PostgreSQL `LISTEN`/`NOTIFY` (the driver
exposes `listen`/`notifications`) is the chosen backbone: every replica LISTENs,
`AdvanceStatus` issues a NOTIFY, and each replica forwards to its local
subscribers. Handler code does not change.

## 10. Authentication and sessions

- `Register`: email, password, full name. Password is hashed with a KDF from the
  crypto stdlib (`pbkdf2` or the strongest available), never stored in clear.
  Entering credentials is the user's action; the app only stores the hash.
- `Login`: verifies the hash, sets a signed session cookie.
- Sessions: a `sessions` table or a signed cookie carrying the user id; a
  `SessionBehavior` pipeline behaviour resolves the current user and role.
- Roles: `customer` and `admin`. An `AdminOnly` behaviour guards admin routes and
  returns 403 for non-admins.
- `Profile`: view and edit personal details and address; view order history.

## 11. Admin

- `AdminDashboard`: new orders, revenue today, low-stock products (`DashboardStats`).
- `ProductManagement`: product CRUD, image URL, price, stock, category, and the
  vegetarian flag.
- `OrderManagement`: list and filter orders, view detail, advance status (this is
  the action that drives the customer's live status).
- `UserManagement`: list customers (read-only support view).
- `Inventory`: ingredient stock (optional, from the ingredient tables).

Admin pages are `.nsx` views under `Features/Admin/*/views/`, reactive where it
helps (the order list updates live as new orders arrive, via the same SSE seam on
an `orders` topic).

## 12. Screens, routes, slices

| Screen | Route(s) | Slice(s) |
| --- | --- | --- |
| Home / Menu | `GET /`, `GET /categories`, `GET /products` | Catalog/GetCategories, Catalog/GetProducts |
| Product detail | `GET /products/{id}` | Catalog/GetProductDetail (product + modifiers) |
| Cart | `GET /cart`, `POST /cart/add`, `POST /cart/update`, `POST /cart/remove` | Cart/GetCart, AddToCart, UpdateCartItem, RemoveCartItem |
| Checkout | `GET /checkout`, `POST /checkout` | Checkout/GetCheckout, PlaceOrder |
| Order confirmation | `GET /orders/{id}` | Orders/GetOrder |
| Live order status | `GET /orders/{id}/events` (SSE) | Orders/OrderEvents |
| Order history | `GET /orders` | Orders/GetOrderHistory |
| Login / Register | `GET/POST /login`, `GET/POST /register`, `POST /logout` | Auth/Login, Auth/Register, Auth/Logout |
| Profile | `GET/POST /profile` | Profile/GetProfile, UpdateProfile |
| Admin dashboard | `GET /admin` | Admin/GetDashboard |
| Product mgmt | `GET/POST /admin/products…` | Admin/Products/* |
| Order mgmt | `GET /admin/orders`, `POST /admin/orders/{id}/advance` | Admin/Orders/List, AdvanceStatus |
| User mgmt | `GET /admin/users` | Admin/Users/List |
| Inventory | `GET /admin/inventory` | Admin/Inventory/* |

`app.sse` matches exact paths, so the events route uses a query form
(`GET /orders/events?order={id}`) or a small router extension is added to support
one path parameter for SSE routes. The design prefers extending `app.sse` to
accept a single `{id}` parameter so the URLs read naturally; this is a minor,
contained framework change.

## 13. Views (.nsx)

A shared layout plus per-feature partials, all `.nsx`:

- `Shared/views/layout.nsx`: the page shell (head, Datastar script include, nav,
  cart badge), a `page(title, body)` function.
- `Features/Catalog/views/catalog.nsx`: category sidebar, product grid, product
  card, product detail with modifier selectors.
- `Features/Cart/views/cart.nsx`: cart panel, cart line, cart badge, totals.
- `Features/Checkout/views/checkout.nsx`: the checkout form and summary.
- `Features/Orders/views/orders.nsx`: confirmation, live status fragment, history
  list, reorder button.
- `Features/Auth/views/auth.nsx`: login and register forms with inline validation.
- `Features/Admin/views/*.nsx`: dashboard, product form and table, order table,
  user table, inventory.

The Datastar client script is served from `wwwroot` (vendored, not a CDN, to
respect the offline and CSP posture). Tailwind builds `wwwroot/app.css` from the
`.nsx` sources.

## 14. Migration from the current code

The current tree has a working catalogue on `.nsx` and a superficial order slice
that violates conventions. Changes:

1. **Schema to UUID** (section 4): replace the SERIAL int schema; regenerate seed.
   Entities move UUID id fields to `str.Str`.
2. **Real cart and checkout**: replace the single-line `createOrder` with the cart
   plus the `PlaceOrder` transaction (sections 7 and 8).
3. **Remove inline HTML** from the order handlers and the SSE handler: move all
   markup into `Features/Orders/views/orders.nsx` and produce SSE patches with
   nova-datastar `Sse` verbs, not `web.sse.writeEvent` string building.
4. **Repositories**: split `ShopStore` into `Db` + per-area repositories.
5. Keep: the `web.sse` `EventBus` and `app.sse` route seam (they are the transport
   the datastar `Sse` writes over), the `KYTE_PORT` wiring, and the general slice
   layout.

## 15. Orchestrated deployment

- Build a native shop binary honouring `KYTE_PORT`.
- Bring up NovaDB (orchestrator config and leader-lease store) and PostgreSQL
  (application data).
- `app.yaml` (project root): `kind: App`, `replicas.min = N`, **`lb.handoff: true`**, plus the `config:` block that is the app's single config source
  (fd-handoff is required for SSE; the buffering proxy modes break long-lived
  streams), `health.path` a cheap 200 route, resource limits.
- `orchd.json` (manifests dir, discovery file, store on NovaDB) and `service.json`
  (front port, discovery service). `orchd` supervises replicas and writes the
  discovery file; `service` load-balances and hands off client sockets.
- The multi-replica `EventBus` uses PostgreSQL `LISTEN`/`NOTIFY` (section 9).
- Acceptance: an adapted `acceptance/slice.sh` that seeds the shop, drives load
  through the front port, performs a rolling deploy with zero dropped requests,
  kills a replica and checks recovery, restarts `orchd` and checks the data plane
  keeps serving, and verifies an order survives a NovaDB restart of the control
  plane.

## 16. Build, run, test

- Offline gate (`run_all.sh`): `kyte build` compiles the whole app; a small set of
  `@test` slices run against a test database or fixtures; the view functions are
  compile-checked.
- Live (`run-live.sh`): create and seed `sandwichshop`, run the app, drive the
  full flow (browse, add to cart, checkout, advance status, watch live), then the
  orchestrated variant.

## 17. Open decisions for review

1. UUID primary keys as specified, or int SERIAL for simplicity. This design uses
   UUID to match the shared schema.
2. Sessions in a table versus a signed cookie only. This design allows either; a
   signed cookie is the default.
3. Tax rate: a fixed percentage constant for the demo.
4. The `app.sse` single-path-parameter extension (section 12): do it, or use the
   query-string form to avoid a framework change.

## 18. Entities, DTOs, and mappers

The data layer follows the clean-architecture split that ASP.NET Core teaches
with AutoMapper (entities are the persistence shape, DTOs are the shapes that
leave the server, a mapper projects one to the other), adapted to Kyte.

**Entities** (`src/Domain/Entities`) are one struct per table, fields in
snake_case to mirror the columns, owned `string` so an entity outlives the
result buffer and is safe to mutate and write back. They are the read/write
model for base-table access.

**DTOs** are the shapes the views and responses use. A read DTO is DERIVED from
an entity: it drops columns (a `ProductDto` has no `stock_quantity`), renames
(`image_url` -> `imageUrl`, `total_amount` -> `total`), or omits secrets (a
`UserDto` never carries `password_hash`). Read DTOs that are mapped from entities
use owned `string`, so the map is a safe owned-to-owned copy with no dangling
view into the entity.

**Mappers** (`Features/<F>/Mappers`) are the AutoMapper-Profile stand-in:
one function per entity->DTO, each line a convention copy or an explicit rename
(the `ForMember` equivalent). Mapping happens in the handler (the controller
step), never in the repository. A future compiler `..from(entity)` spread would
generate the convention copies and leave only the renames and derived fields.

**Where entities are used vs read-model projections.** Base-table reads and
writes go through entities: Product/Category (Catalog), User (Auth), Order and
OrderEvent (Orders/Admin/Ops). But composite and aggregate reads stay direct
read-model projections bound straight from a tailored `SELECT` (the CQRS read
side, the `ProjectTo` equivalent), because they do not map from a single entity:
the Catalog modifier list (JOIN product_modifiers), the cart lines (JOIN
products) and summary (SUM), and the admin dashboard stats (COUNT/SUM
subqueries). Putting an entity in front of those would add round-trips, not
clarity, so each such site is a projection with a comment saying so.

Entities for tables the app does not yet read as objects (Modifier,
ProductModifier, CartItem, Ingredient, ProductIngredient) exist as the
schema-complete persistence model, ready for the first object-CRUD screen (for
example an admin "edit product") that reads a full row, mutates it, and writes
it back.
