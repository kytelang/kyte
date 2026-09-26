# Kyte hypermedia enhancements: design and acceptance criteria

This document plans a set of enhancements that strengthen Kyte as a hypermedia first
language, the server renders HTML fragments and a client library (htmx, datastar, unpoly,
htmz, alpine) swaps them into the page. The proposals are grounded in the current code and
grouped into tiers by leverage and risk. Each item states what it is, why it matters for
hypermedia, the implementation plan with the files it touches, testable acceptance criteria,
an effort estimate, and the layer it lives in (stdlib, scaffold, or compiler).

Nothing here changes the language's stance: single page and JSON first patterns stay out of
scope. These features make the server driven, HTML over the wire model more ergonomic, safer,
and refactor friendly.

## Current state (as built today)

- KYX templating: `<tag>` literals parse in `src/frontend/parser.zig` (`parseJsxElement`), type
  as the nominal `Html` string (`src/frontend/type_checker.zig`, the one way `Html` to `string`
  coercion and the `string` to `Html` XSS block), and lower in
  `src/backend/codegen/expressions.zig` (`emitJsxInto` and the `jsxAppend*` helpers). `{expr}`
  auto escapes a plain string, a call returning `Html` is inserted raw, and `response.raw(s)` or
  `s as Html` (`src/lib/std/web/response.ky`) is the single XSS boundary. Composition today is
  only "call a `fn(...): Html`", there is no component, slot, attribute spread, boolean attribute,
  or class list helper. Hypermedia attributes are hand built with string interpolation.
- Web framework (`src/lib/std/web/`): `App` (`app.ky`) with `get/post/put/delete/patch`, `sse`,
  `ws`; `RouteHandler`, `Context`, `Chain` middleware in `routing.ky`; `Context.bind<T>()` merges
  cookies, query, params, and body via `source()`; `Response` in `response.ky` with `setHeader`,
  `setCookie`, `getHeader`; SSE in `sse.ky` (`EventBus`, `InProcessBus`, `writeEvent`,
  `writeHeartbeat`); CSRF double submit in `csrf.ky`; sessions in `session.ky`; full cookie
  attributes in `cookie.ky`.
- Scaffold: `src/scaffold.zig` and `src/templates.zig` wire five index shells and the sample
  handler returns an HTML fragment with `Content-Type: text/html`.
- Confirmed gaps: no `HX-*` header helpers, no redirect helper in `response.ky`,
  `Response.setCookie` hardcodes `Path=/` and drops HttpOnly, Secure, SameSite, Max-Age even
  though `cookie.ky` supports them, no flash messages, no typed route or URL builder, no server
  side full page versus fragment mechanism, and the only one shot fragment helper is datastar
  specific (`kyte-datastar/src/ds_response.ky`).

## Framework coverage and the neutral core

Kyte scaffolds five client libraries (`src/templates.zig`): htmx, unpoly, htmz, alpine (alpine-ajax),
and datastar. They all follow the "handler returns an HTML fragment" model, but their server driven
control channels differ, so the control surface features below must NOT be htmx only. The design is a
framework neutral core seam plus thin per framework adapters:

- **`web.hyper` (neutral core).** A small `Hypermedia` abstraction that a handler talks to in framework
  neutral terms: detect a hypermedia request, trigger a client event, redirect, retarget or reswap,
  push a history URL, and mark a region for an out of band update. The core auto detects the active
  framework from the request (each sends a distinct header, see the table) or reads it from app config,
  and dispatches to the right adapter.
- **Per framework adapters.** `web.htmx` and `web.unpoly` (and an `web.alpine` shim) live in the stdlib
  and implement the neutral operations with that framework's real mechanism. datastar already has a
  first party package (`kyte-datastar`, `ds_response.patch` emitting `datastar-patch-elements`); the
  neutral core routes datastar operations through that package rather than duplicating it. htmz is
  intentionally minimal (hidden iframe, plain HTML and standard HTTP redirects), so it implements only
  the operations it can and reports the rest as not applicable.

Capability to mechanism map (this is the contract the adapters implement):

| Neutral operation | htmx | unpoly | alpine-ajax | datastar | htmz |
|---|---|---|---|---|---|
| Detect hypermedia request | `HX-Request` | `X-Up-Target` / `X-Up-Version` | `X-Alpine-Request` | `datastar-request` | (none; treat as full nav) |
| Trigger client event | `HX-Trigger` | `X-Up-Events` | dispatch via response id merge | `datastar-patch-signals` / execute script (SSE) | not applicable |
| Redirect | `HX-Redirect` / `HX-Location` | `X-Up-Location` (+ status) | `X-Alpine-Redirect` | signal patch or execute script (SSE) | standard `303 Location` (works through the iframe) |
| Retarget | `HX-Retarget` | `X-Up-Target` (response) | target by element id | element id in the SSE patch | not applicable |
| Reswap | `HX-Reswap` | `X-Up-*` swap hints | merge strategy by id | morph by id | not applicable |
| Push history URL | `HX-Push-Url` / `HX-Replace-Url` | `X-Up-Location` + method | not applicable | execute script (SSE) | not applicable |
| Out of band / multi region | `hx-swap-oob` attribute | multiple targets / `[up-hungry]` | multiple elements merged by id | multiple ids in one patch | not applicable |
| Server push (SSE) | SSE extension: named `event:` + fragment | `[up-poll]` or SSE | id merge over SSE | native `datastar-patch-elements` (has package helper) | not applicable |

So each control surface item below (1, 2, 3, 4, 9) is specified against the neutral core, and its
acceptance criteria require at least the htmx and unpoly adapters plus the datastar route through the
package, with alpine covered where the mechanism exists and htmz explicitly reporting not applicable
for operations it cannot express. Items that are framework independent (5 cookies and flash, 6 CSRF and
validation, 7 typed URL builder, 10 fragment content type, 8 and 12 KYX language features) work
identically for all five, because they operate on plain HTTP and HTML rather than a framework's control
channel; each of those still gets one acceptance check per scaffold to prove it renders and posts under
that client library.

## How to read the acceptance criteria

Every item is "done" only when its acceptance criteria pass. Criteria are written to be
executable: each one should map to a conformance case under `conformance/cases`, a web
example under `examples/`, or a live check against `examples/kyte-pg-web`. The standing bars
for the whole document are:

- The positive corpus stays green (`bash conformance/run.sh -j`).
- The XSS boundary is never widened: user strings interpolated into KYX stay auto escaped, and
  the only raw paths remain `response.raw` and `as Html`.
- `examples/kyte-pg-web` still builds, serves all routes with `200`, and its live board SSE and
  cart write flow still work.

---

# Tier 1: highest leverage, low risk, stdlib only

## 1. Neutral hypermedia control core plus per framework adapters

**What.** A `web.hyper` neutral core and thin per framework adapters that give a handler framework
neutral control operations: `ctx.isHypermedia()`, `ctx.wantsFragment()`, `hyper.trigger(res, event)`,
`hyper.redirect(res, url)`, `hyper.retarget(res, selector)`, `hyper.reswap(res, mode)`,
`hyper.pushUrl(res, url)`. Each operation dispatches to the active framework's mechanism per the
capability map above. The htmx adapter emits the `HX-*` headers, the unpoly adapter emits `X-Up-*`, the
alpine adapter uses id merge and `X-Alpine-Redirect`, datastar routes through the `kyte-datastar`
package, and htmz falls back to plain HTTP where it can and reports not applicable otherwise.

**Why hypermedia.** This server driven control channel (trigger an event, redirect, retarget, reswap,
push history) is the heart of every one of these libraries, but each expresses it differently. A neutral
core means a handler is written once and works whichever client library the app scaffolded, and it stops
handlers from hand writing header strings.

**Plan.**
- New `src/lib/std/web/hyper.ky` defining the neutral operations and a `Framework` selector, plus the
  auto detection that reads the distinguishing request header for each library.
- New `src/lib/std/web/htmx.ky` and `src/lib/std/web/unpoly.ky` adapters, and an `alpine` shim; the
  datastar path calls into the `kyte-datastar` package rather than duplicating it.
- Add `isHypermedia`, `wantsFragment`, and framework accessor methods to `Context` in
  `src/lib/std/web/routing.ky` (request header reads only, no new state).
- No compiler change. Register nothing.

**Acceptance criteria.**
- For htmx: `trigger` emits `HX-Trigger` (bare name and JSON map forms), `redirect` emits `HX-Redirect`,
  `retarget` emits `HX-Retarget`, `reswap` emits `HX-Reswap`, `pushUrl` emits `HX-Push-Url`, asserted
  against `Response.serialize`.
- For unpoly: the same neutral calls emit the corresponding `X-Up-*` headers (`X-Up-Events`,
  `X-Up-Location`, `X-Up-Target`).
- For datastar: the neutral calls produce the datastar equivalent through `kyte-datastar` (signal or
  element patch), not `HX-*` headers.
- For alpine: `redirect` emits `X-Alpine-Redirect`; retarget resolves by element id.
- For htmz: `redirect` emits a standard `303 Location`; operations with no htmz mechanism return a clear
  not applicable result rather than emitting a wrong header.
- `ctx.isHypermedia()` is true for a request carrying any framework's marker header and false for a plain
  browser navigation; `wantsFragment()` matches per the table.
- The corpus stays green and the helpers add zero cost when unused.

**Effort.** M (was S when scoped htmx only; the adapters add breadth). **Layer.** stdlib.

## 2. Redirect and Post/Redirect/Get helpers on Response

**What.** `response.redirect(url, status)` (default `303`), `response.seeOther(url)`, and an
htmx aware `response.redirectHx(ctx, url)` that emits `HX-Redirect` or `HX-Location` when the
request is an htmx call and a normal `303` with a `Location` header otherwise.

**Why hypermedia.** Post then Redirect then Get is the canonical hypermedia write flow. htmx needs
`HX-Redirect` because a plain `Location` on an XHR is swallowed by the browser. There is no
redirect helper at all in `response.ky` today, so every write flow reinvents it.

**Plan.**
- Add the three methods to `Response` in `src/lib/std/web/response.ky`.
- `redirect` sets the status and the `Location` header and leaves the body empty.
- `redirectHx` depends on item 1's `ctx.isHtmx()` and header helpers.

**Acceptance criteria.**
- `response.redirect("/x")` yields status `303` and `Location: /x` in serialized output; a custom
  status argument is honoured.
- `redirectHx` on a request with `HX-Request: true` emits `HX-Redirect: /x` and no `Location`; on a
  plain request it emits `303` with `Location: /x`.
- A web example (extend `examples/kyte-pg-web` or a new small example) performs a POST that
  redirects to a GET and the flow returns the target page.

**Across frameworks.** `redirect` delegates to item 1's neutral core, so the htmx build emits
`HX-Redirect`, unpoly emits `X-Up-Location`, alpine emits `X-Alpine-Redirect`, datastar performs the
redirect over its SSE channel, and htmz gets a plain `303 Location`. The acceptance flow is run against
at least htmx, unpoly, and htmz to prove the browser lands on the target for each.

**Effort.** S. **Layer.** stdlib.

## 3. Server side layout: full page versus fragment rendering

**What.** A layout convention so one route serves a full HTML page to a fresh browser and a bare
fragment to a hypermedia request. Add `ctx.wantsFragment()` (true for `HX-Request`, unpoly's
`X-Up-Target`, or an htmz target), and a `render(layout, fragment)` helper that returns the
fragment alone on a hypermedia request and the shell wrapped fragment on a hard navigation.
Emit `Vary: HX-Request` automatically so shared caches stay correct.

**Why hypermedia.** This is the core progressive enhancement pattern: the same URL is a real page
on first load and a swap target afterwards. Kyte's shell is a static `wwwroot/index.html`, so a
full page cannot currently be composed on the server around a fragment.

**Plan.**
- `ctx.wantsFragment()` in `src/lib/std/web/routing.ky` (reads request headers).
- A `web.view` (or `web.layout`) helper that takes a layout function `fn(inner: Html): Html` and a
  fragment `Html`, returning one or the other based on `wantsFragment()`, and sets `Vary`.
- A scaffold sample in `src/templates.zig` showing a route that uses it.

**Acceptance criteria.**
- The same handler returns only the fragment markup for a request with `HX-Request: true`, and the
  full shell plus fragment for a request without it, verified by asserting the presence or absence
  of the shell wrapper (for example `<html`).
- The fragment and full responses both carry `Vary: HX-Request`.
- Auto escaping is unchanged: the fragment composed into the layout is inserted as `Html`, user
  strings inside it stay escaped.

**Across frameworks.** `wantsFragment()` recognises each library's request marker (`HX-Request`,
`X-Up-Target`, `X-Alpine-Request`, `datastar-request`); htmz has no marker, so it always gets the full
page, which is correct for its iframe model. The `Vary` header names the markers the app actually keys on.
Acceptance is checked for htmx and unpoly (fragment on marked request, full page otherwise) and for htmz
(always full page).

**Effort.** M. **Layer.** stdlib and scaffold.

---

# Tier 2: the write half and security

## 4. Out of band swap composition

**What.** An `oob(fragment)` helper that marks a fragment for an out of band swap (`hx-swap-oob="true"`
for htmx, the datastar equivalent for that scaffold) and a response builder that concatenates a
primary fragment plus N out of band fragments, so one response can update several disjoint regions
(for example a list row and the cart badge together).

**Why hypermedia.** Out of band swaps are how a single hypermedia response updates multiple regions,
the idiomatic alternative to client held JSON state. The `AddToCart` handler in
`examples/kyte-pg-web` already wants this: it can only patch the badge today.

**Plan.**
- `oob()` and a small multi fragment response assembler in `src/lib/std/web/hx.ky` (ties to item 1).
- Optional KYX sugar for an `<oob>` element is deferred to a compiler item; the stdlib helper is
  enough to ship the capability.

**Acceptance criteria.**
- A response built from a primary fragment plus two out of band fragments serialises to a body that
  contains all three, and each out of band fragment carries the swap marker attribute.
- A web example updates two regions from one POST and both regions reflect the change.
- Escaping is preserved inside every fragment.

**Across frameworks.** The out of band marker differs: htmx uses `hx-swap-oob="true"`, alpine and
datastar merge every element that carries a matching `id` (so multi region is implicit), and unpoly uses
multiple targets or `[up-hungry]`. The `oob()` helper takes the framework from the neutral core and emits
the right marker (or, for the id merge libraries, simply ensures the fragment has an id). htmz cannot
express out of band updates and the helper reports not applicable there.

**Effort.** M. **Layer.** stdlib (optional later compiler sugar).

## 5. Secure cookie and session response ergonomics plus flash messages

**What.** Make `Response.setCookie` accept the full `web.cookie.Cookie` (HttpOnly, Secure, SameSite,
Max-Age, Path, Domain) instead of hardcoding `Path=/`; add signed session cookies; add a flash
message API (`ctx.flash("msg")`) that survives exactly one redirect.

**Why hypermedia.** Post then Redirect then Get depends on flash messages to show "Saved" after the
redirect. Separately, session cookies today serialise without HttpOnly or SameSite, which is a real
security gap: `cookie.ky` already implements the attributes, but `Response.serialize` does not use
them.

**Plan.**
- Change `Response.setCookie` and `Response.serialize` in `src/lib/std/web/response.ky` to render the
  full `Cookie` attribute set from `src/lib/std/web/cookie.ky`.
- Add signed cookie support (HMAC over the value) and a flash store keyed in the session, in
  `src/lib/std/web/session.ky`.

**Acceptance criteria.**
- A cookie set with HttpOnly, Secure, SameSite=Lax, and Max-Age serialises with every attribute
  present; the default session cookie is HttpOnly and SameSite by default.
- A tampered signed cookie is rejected (treated as absent), an untampered one round trips.
- A flash message set before a redirect is visible on the next GET and absent on the GET after that.
- The XSS boundary is unchanged and the corpus stays green.

**Effort.** M. **Layer.** stdlib.

## 6. Form, CSRF, and validation view helpers

**What.** A `csrfField()` KYX helper that injects the hidden `_csrf` input matching `csrf.ky`'s token
name, plus helpers to render a `web.validation.ValidationResult` as inline per field errors, so an
invalid form can be re rendered as a fragment with messages beside each field.

**Why hypermedia.** Forms are the write half of hypermedia and validation errors come back as a re
rendered fragment, not as JSON. `validation.ky` (`Rules`, `ValidationResult`) and `csrf.ky` exist but
nothing bridges them into KYX views today.

**Plan.**
- New `web.forms` helpers returning `Html`: `csrfField(ctx)`, `fieldError(result, "name")`,
  `hasError(result, "name")`.
- A scaffold sample form that posts, validates, and re renders itself with errors on failure.

**Acceptance criteria.**
- `csrfField(ctx)` renders a hidden input whose name and value match what `csrf.ky` verifies, and a
  POST carrying it passes CSRF while a POST without it is rejected.
- `fieldError` renders the message for a failing field and nothing for a passing field, with the
  message auto escaped.
- A web example round trips an invalid submit into a re rendered fragment showing the errors, then a
  valid submit succeeds.

**Effort.** M. **Layer.** stdlib and scaffold.

---

# Tier 3: refactor safety and ergonomics

## 7. Typed route and URL builder for hypermedia targets

**What.** Named routes with typed parameters so views build URLs with `url(Routes.claimOrder, phase, id)`
instead of interpolating `` `/${phase}/claim?order=${o.id}` ``. A stronger version checks the URL
against registered routes at compile time.

**Why hypermedia.** In a hypermedia app the URLs are the API surface and they live inside markup
attributes (`hx-get`, `data-on`, `href`). String interpolated URLs are the most common breakage when a
route is renamed; a typed builder makes those targets refactor safe.

**Plan.**
- A route registry keyed by name in `src/lib/std/web/routing.ky` and a `url()` builder that formats a
  named route with its parameters.
- A stronger, optional variant adds a check in `src/frontend/type_checker.zig` that a `url(...)` call
  names a registered route with the right parameter count.

**Acceptance criteria.**
- `url(name, args...)` produces the same string the route was registered with, including path
  parameter substitution and query parameters.
- Renaming a route's path updates every `url()` result without touching call sites.
- In the compiler checked variant, an unknown route name or wrong parameter count is a build error.

**Effort.** M for the stdlib builder, L for the compiler checked variant. **Layer.** stdlib, optionally
compiler.

## 9. htmx native SSE fragment helper

**What.** A stdlib one shot and streaming helper that emits SSE frames shaped for htmx's SSE
extension (a named `event:` plus the fragment for an `sse-swap` target), analogous to
`kyte-datastar`'s `patch()`, so htmx, unpoly, and alpine apps get first class server push without a
package.

**Why hypermedia.** SSE is the sanctioned hypermedia push mechanism. datastar users get an ergonomic
helper today, but htmx and unpoly users must hand write `writeEvent` frames.

**Plan.**
- Extend `src/lib/std/web/sse.ky` with a fragment oriented writer (event name plus `Html` payload) and
  a one shot variant that writes a single frame and closes.
- Scaffold wiring per framework in `src/templates.zig`.

**Acceptance criteria.**
- The helper emits a well formed SSE frame with the given event name and the fragment as data; a live
  check receives the frame and the client swaps it.
- The one shot form closes the stream after one frame; the streaming form keeps it open and heartbeats.
- `examples/kyte-pg-web`'s live board continues to work (datastar path unaffected).

**Across frameworks.** datastar already has its ergonomic SSE helper in `kyte-datastar`, so this item
serves the other libraries: the htmx SSE extension (named `event:` plus fragment for an `sse-swap`
target), unpoly polling or SSE, and alpine id merge over SSE. The neutral core picks the frame shape from
the active framework; the acceptance frame is validated for the htmx SSE extension shape at minimum, and
the datastar helper is left as the reference implementation.

**Effort.** M. **Layer.** stdlib and scaffold.

## 10. Typed fragment response distinct from a full page

**What.** `response.fragment(html)` that sets `Content-Type: text/html; charset=utf-8` and
`Vary: HX-Request` automatically, and optionally a nominal `Fragment` versus `Page` distinction so a
handler's return intent is explicit.

**Why hypermedia.** Every handler repeats the content type header today and none set `Vary`, which
corrupts shared caches when the same URL can return a fragment or a full page (see item 3).

**Plan.**
- Add `response.fragment(html)` and `response.page(html)` to `src/lib/std/web/response.ky`.
- The optional nominal type lives in `src/frontend/type_checker.zig`; the helper alone is enough to
  ship.

**Acceptance criteria.**
- `response.fragment(h)` sets the HTML content type and `Vary: HX-Request` without the caller writing
  headers.
- The scaffold sample handler uses `response.fragment` and drops its manual `setHeader` call.
- Corpus stays green.

**Effort.** S for the helper, M for the typed variant. **Layer.** stdlib, optionally compiler.

## 11. Scaffold: a per framework hypermedia demo that exercises the new capabilities

**What.** Extend the generated scaffold so the sample demonstrates a write with Post then Redirect
then Get, a flash message, an out of band update, and an `HX-Trigger` toast, rather than only a single
GET and swap card.

**Why hypermedia.** The scaffold is how users learn the idiom. If it only shows the simplest swap, the
capabilities added above will not be discovered.

**Plan.**
- Update `src/templates.zig` and `src/scaffold.zig` per framework, depending on items 1, 2, 4, and 5.

**Acceptance criteria.**
- `kyte init web --framework htmx` (and each other framework) scaffolds a project that builds and runs.
- The generated app demonstrates a redirect after write, a flash message, and one out of band update
  that a live check confirms.

**Effort.** S to M. **Layer.** scaffold (depends on Tier 1 and 2).

---

# Tier 4: compiler investments that raise KYX's ceiling

## 8. KYX conditional and boolean attributes, attribute spread, and class list

**What.** In `parseJsxElement`: allow a boolean attribute form (`disabled={cond}` renders the attribute
only when the value is true), an attribute spread (`{...attrs}` from a map), and a class list helper
(`class={classList(...)}`), instead of interpolating attribute strings.

**Why hypermedia.** Hypermedia UIs live in HTML attributes: `hx-*`, `data-*`, `aria-*`, conditional
`disabled` or `checked`. Safe composition of these attributes is the ergonomic heart of a hypermedia
templating language; today they are built by string concatenation, which is both verbose and an
injection risk if done carelessly.

**Plan.**
- Parser: extend `parseJsxElement` and `parseJsxAttrName` in `src/frontend/parser.zig`.
- AST: extend `JsxAttribute` and `JsxAttributeValue` in `src/frontend/ast.zig`.
- Codegen: extend `emitJsxInto` and the `jsxAppend*` helpers in
  `src/backend/codegen/expressions.zig` to omit a false boolean attribute, expand a spread map, and
  render a class list, with attribute values escaped.

**Acceptance criteria.**
- A boolean attribute is present in output when its expression is true and absent when false.
- An attribute spread from a map renders each key and value, with values escaped.
- `classList` composes the correct space separated class string from its conditions.
- Attribute value escaping is enforced: a user string in an attribute cannot break out of the quotes.
- New expect_fail cases cover misuse (for example a non map spread) and the positive corpus stays
  green.

**Effort.** M to L. **Layer.** compiler.

## 12. KYX component abstraction with props and children slots

**What.** First class components: a capitalised element `<Card title={...}>children</Card>` compiles to
a `fn(props, children: Html): Html` call, giving named slots and typed props beyond a bare function
call.

**Why hypermedia.** Server rendered view composition is the whole rendering model. Slots and props make
reusable partials (cards, modals, list rows) ergonomic and typed, which reduces the raw string
composition that KYX leans on today.

**Plan.**
- Parser: route capitalised tags in `parseJsxElement` to a component call form in
  `src/frontend/parser.zig`.
- Sema: resolve the component function and type check its props in the sema and type checker.
- Codegen: lower to the function call passing props and the children `Html` in
  `src/backend/codegen/expressions.zig`.

**Acceptance criteria.**
- `<Card title="x">inner</Card>` type checks against `fn Card(title: string, children: Html): Html` and
  renders identically to calling that function directly.
- A missing or wrong typed prop is a build error.
- Children are passed as `Html` and their auto escaping matches the current KYX rules.
- New corpus cases cover a component with props, a component with children, and nested components.

**Effort.** L. **Layer.** compiler.

---

# Sequencing and rollout

Suggested order: items 1, 2, 3 first (highest leverage, mostly stdlib), then 4, 5, 6, then 7, 9, 10, 11,
then the compiler investments 8 and 12. Items 1 to 7 and 9 to 11 are stdlib or scaffold and low risk;
8 and 12 are the compiler changes that most raise KYX's ceiling and should each land behind the full
corpus and ASAN gates with new conformance cases.

A sensible first slice to implement and gate together is items 1, 2, 10, plus the cookie security fix in
item 5: all pure stdlib, immediately useful in every handler, and independently testable. Each slice
lands as one reviewed commit with its conformance cases, the corpus green, and `examples/kyte-pg-web`
re verified end to end.

# Cross cutting acceptance gates (apply to every item)

- `bash conformance/run.sh -j` stays green, and each item adds at least one conformance case that fails
  before the change and passes after.
- The XSS boundary is never widened: the only raw insertion paths remain `response.raw` and `as Html`,
  and a regression case proves a user string stays escaped in the new surface.
- `examples/kyte-pg-web` builds, serves every route with `200`, its cart write still persists and re
  renders, and its live board SSE still streams.
- Documentation: the web chapter of the guide (`docs/guide/17-web.md`) gains a short section per shipped
  item, kept in sync with `kyte-web`.
