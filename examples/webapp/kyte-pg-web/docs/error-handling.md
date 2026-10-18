# Handling errors in a hypermedia app

Errors in this shop are not JSON, they are HTML fragments the browser swaps into the
page, so the person using the app sees the problem in place. This note explains the
three kinds of error and how each is handled, and the reasoning behind it.

## The three kinds of error

Kyte does not have thrown, stack-unwound exceptions. Its error model is return based:
a function that can fail returns a value union `T | SomeError`, and callers deal with
it explicitly. That splits web errors cleanly into three tiers.

### 1. Bad input, handled by validation

A malformed form body or a missing field does not crash anything: the serde binder
fills the bound struct with defaults rather than failing, so `ctx.bind<T>()` always
returns a value. The handler then validates it (see `web.validation` and the
`RegisterValidator`) and, on failure, returns an error fragment. Nothing special is
needed here beyond checking the bound value.

### 2. Expected domain errors, modelled and rendered

Not-found, not-allowed, and business-rule failures are modelled with an `exception`
type, `Shared/ShopError.ky`:

```
pub exception ShopError { NotFound(string), Forbidden(string), BadRequest(string), ... }
```

A fallible step returns `T | ShopError`. A handler keeps its happy path in a `run`
method that returns `Response | ShopError` and propagates failures with `try`; `serve`
converts any error into the banner in exactly one place:

```
async fn serve(self, ctx: Context): Response {
    return await self.run(ctx) catch (e) await renderShopError(e);
}
async fn run(self, ctx: Context): Response | ShopError {
    let q = ctx.bind<GetProductDetail>();
    let prod = await self.repo.product(q.id);
    if (prod.items.get(0) == undefined) {
        return ShopError.NotFound("We couldn't find that item on the menu.");
    }
    ...
    return await ds_response.patch(catalog.productDetail(dto, mods.items));
}
```

`renderShopError` (in `Shared/ShopError.ky`) turns the error into a datastar patch of
`errorFragment(...)`, a red banner inside the `#content` region, with the message
HTML-escaped so data or user text cannot inject markup. Because the error is a normal
patch, the client swaps it in exactly like a success response, and the user sees the
message where the content would have been.

Why this shape rather than `catch` in the middle of the handler: `catch` in Kyte yields
the ok type of the expression, so it cannot turn a `Product | ShopError` directly into a
`Response`. Making the inner `run` return `Response | ShopError` lets `serve`'s single
`catch` produce the `Response`, and keeps every error kind flowing through one renderer.

The JSON sibling app (`nova-notes-api`) uses the identical pattern with an `ApiError`
exception and a `JsonResponse.fromError` renderer, the only difference being that it
renders `{"error":...}` instead of an HTML banner. So the convention is the same across
hypermedia and JSON; only the rendering differs.

### 3. Programming bugs, handled by the platform

An out-of-bounds `list.at(i)`, a nil dereference, or an integer overflow is a `kyte:
panic` that aborts the process. There is no in-process `recover` in the single-reactor
runtime, so a panicking request cannot be turned into a 500 in place. Two things keep
this from being a problem:

- Write panic-free handlers. Prefer `.get(i)` (which returns `T | undefined`) with
  `?? default` or an `if (x != undefined)` narrowing over `.at(i)` on any index that
  came from a request. Bad input already fails soft to defaults, so panics only come
  from genuine bugs.
- Let the platform isolate a crash. The app runs as several replicas behind `proxyd`,
  supervised by the orchestrator: if one replica panics it is restarted and the proxy
  routes around it in the meantime. This is the "let it crash and supervise" model, and
  it is the right fit for a single-reactor server that cannot unwind.

## Tests

`tests/error_test.ky` gates the hypermedia rendering offline (no database): the error
fragment targets `#content` and is styled as an error, the message is HTML-escaped,
`renderShopError` produces a datastar patch carrying the message, and each `ShopError`
variant carries its message. The JSON app's `tests/api_test.ky` covers the same
convention on the API side (404/400 envelopes and the malformed-body-is-400 guarantee).

## Do and don't

- Do model expected failures as a `ShopError` variant and return it from a fallible step.
- Do keep the happy path in `run` returning `Response | ShopError`, and render once in
  `serve` with `catch (e) await renderShopError(e)`.
- Do escape any message that reaches HTML (`renderShopError` already does).
- Don't use `.at(i)` on request-derived indices; use `.get(i)` and narrow.
- Don't expect a panic to become a 500; prevent it, and rely on the orchestrator.
