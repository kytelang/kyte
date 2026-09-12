# nova-notes-api

A small JSON REST API built on the Nova web framework. It is the second reference
app (after the hypermedia sandwich shop, `nova-pg-web`), written to exercise the
parts of the framework the shop does not touch, so the framework gets shaken out on
a genuinely different shape.

## What it is

A CRUD API over an in-memory list of notes. Every response is `application/json`.

| Method | Path              | Purpose                                    | Auth        |
|--------|-------------------|--------------------------------------------|-------------|
| GET    | `/`               | Liveness probe                             | open        |
| GET    | `/notes`          | List all notes (`?tag=` filters by tag)    | open        |
| GET    | `/notes/{id:int}` | Fetch one note (404 if absent)             | open        |
| POST   | `/notes`          | Create from a JSON body (201)              | `x-api-key` |
| PUT    | `/notes/{id:int}` | Full replace (200 or 404)                  | `x-api-key` |
| PATCH  | `/notes/{id:int}` | Partial update (non-empty fields + `done`) | `x-api-key` |
| DELETE | `/notes/{id:int}` | Delete (200 or 404)                        | `x-api-key` |

## How it differs from the shop (the point of a second app)

The shop is hypermedia: form-encoded POSTs, datastar HTML fragment responses,
string path params, mostly GET/POST. This app deliberately covers the other side:

- **JSON request bodies** (SPA style), bound with `ctx.bind<T>()` where the shop
  binds form data.
- **The full verb set** including PUT, PATCH, DELETE (the shop is GET/POST).
- **A middleware stack** via `app.use`: a `RequestLogger` that wraps (logs before,
  stamps `x-served-by` after) and an `ApiKeyGuard` that short-circuits mutating
  requests with 401 when `x-api-key` is missing or wrong. Reads stay open.
- **JSON responses** built from the `@serializable`-generated `Note__toJson`.
- **Typed `{id:int}` path params**, so the 400 (bad typed param) and 405
  (wrong verb) paths are exercised, not just 200/404.
- **Shared, mutable in-memory state** (`NoteStore`, a `class`) written by
  create/replace/patch/delete and read by GET across many async requests. This is
  the same "shared instance mutated across repeated async dispatch" shape that the
  earlier `any`-boxed handler experiment could not survive; the direct
  `RouteHandler` path handles it (300 concurrent writes land with unique ids and
  no crash).

Otherwise the wiring is identical to the shop: per-feature `routes.ky` with
`registerNotes(ctx)`, a concrete `AppContext` holding `app + store + settings`,
and layered typed config (`config.yaml` + `.fromEnv` for the secret API key).

## Error handling

Errors come in three kinds, handled three ways:

1. **Bad input** (malformed JSON, missing/wrong-typed fields). The serde binder fails
   *soft* to struct defaults, so it never panics; the handler validates the bound
   value and returns a 4xx. `test_malformed_json_body_is_400_not_crash` proves a
   `{ this is not json` body yields a clean 400, not a crash.
2. **Expected domain errors** (not-found, bad-request, unauthorized, conflict). Modelled
   with Nova's return-based error model, not thrown exceptions: `Shared/ApiError.ky`
   is an `exception` carrying a status + message. A fallible operation returns
   `T | ApiError` (see `requireNote`); a handler's `run` propagates it with `try`, and
   `serve` converts it once with `catch (e) JsonResponse.fromError(e)` into a JSON
   `{"error":...}` with the mapped status. This keeps the happy path linear and the
   error rendering in one place per handler.
3. **Programming bugs** (out-of-bounds `.at`, nil deref, overflow). These `nova: panic`
   and abort the process; Nova has no in-process `recover`. The defence is to write
   panic-free handlers (use `.get` + `?? default` / `undefined` narrowing, never `.at`
   on untrusted input, which is why the store uses `.get`), and to run behind the
   orchestrator so a crashed replica is restarted while proxyd routes around it.

`tests/api_test.ky` covers the domain-error paths (404/400 with the JSON envelope on
every verb that looks a note up) and the malformed-body guarantee.

## Framework fix this app surfaced

The direct-handler dispatch dropped the `typedBad` (400) and `methodNotAllowed`
(405) signals that the mediator path already honoured: a non-integer id on a
`{id:int}` route, or a wrong verb on an existing path, fell through to 404. The
shop hides this because its path params are strings. Fixed in the framework
(`web/app.ky` `dispatch`) so both the direct and mediator paths report 400/405
consistently. Covered by `tests/api_test.ky`.

## Known characteristic (not a regression)

Under `NOVA_ARC_AUDIT=1`, a built `App` leaves a small constant footprint live at
process exit (a bare one-handler app: 3 objects / 40 bytes). This is an
App-lifetime leak in the framework's own internal containers, not a per-request
leak: it does not grow under load, and a server builds exactly one `App` for its
whole lifetime. It affects the shop equally and predates this app.

## Run it

```bash
kyte build
NOTES_API_KEY=s3cret ./build/debug/bin/nova-notes-api      # listens on :8098

curl localhost:8098/notes
curl -X POST localhost:8098/notes \
  -H 'content-type: application/json' -H 'x-api-key: s3cret' \
  -d '{"title":"Buy milk","tag":"home"}'
```

## Test it (offline, no socket)

```bash
kyte test tests/api_test.ky
```

Drives synthetic requests through `app.dispatch` and asserts on status codes and
JSON bodies, covering the verb set, JSON binding, the middleware chain, and the
typed-param / wrong-verb paths.
