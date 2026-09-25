# 22. Building and distributing

This chapter covers the mechanics of turning Kyte source into something you can ship: compiling a
single file, building a project, choosing a hypermedia framework for a web app, and cross-compiling a
program for another operating system.

## Compiling one file

The simplest build takes one file to one native executable:

```sh
kyte hello.ky -o hello
./hello
```

`kyte test file.ky` compiles and runs the `@test` functions in a file instead of producing a
standalone binary. This is what the guide's examples use.

## Building a project

Real applications are more than one file. `kyte init` scaffolds a project, and `kyte build` compiles
it:

```sh
kyte init web --name shop      # scaffold a web app (also: desktop)
cd shop
kyte build                     # debug build
kyte build --release           # optimised build
kyte run                       # build (debug) and run in one step
kyte run -- --migrate          # run with args: everything after -- goes to the program
```

A project has a `project.json` at its root that names it, sets its version and type, and lists its
package dependencies. `kyte build` reads it, compiles every source file under `src/`, links against the
runtime, and writes the result under `build/<profile>/`, with the binary in `build/<profile>/bin/`.
Dependencies declared in `project.json` are fetched with `kyte get`.

`kyte run` is the inner-loop shortcut: it builds the project (debug by default) and then executes the
resulting binary. Build flags before `--` pass through to the build (`kyte run --release`,
`kyte run --file src/other.ky`, `kyte run --target ...`), and everything after `--` is forwarded to your
program. A build failure aborts before the program runs, and `kyte run` exits with the program's own exit
code, so it composes in scripts and doubles as a gate, for example `kyte run -- --migrate` to apply schema
migrations (chapter 23) and fail if one fails.

## Choosing a hypermedia framework for a web app

A `web` project is hypermedia-first: handlers return small HTML fragments, and a client-side library
swaps those fragments into the page. `kyte init web` wires one such library into the scaffold's
`wwwroot/index.html` (its CDN `<script>` tag and a small demo widget) so a new app is interactive out of
the box. Pick it with `--framework` (short form `-f`):

```sh
kyte init web --name shop                      # htmx (the default)
kyte init web --name shop --framework datastar
kyte init web --name shop -f unpoly
```

The accepted values are:

| `--framework` | What it is |
|---------------|------------|
| `htmx` (default) | The most widely used option. Attributes like `hx-get` fetch a fragment and swap it into a target element. |
| `datastar` | Signals-based reactivity driven from the server. Its server actions read a live stream, which Kyte serves through `web.sse` (Chapter 17). |
| `unpoly` | Progressive enhancement built around full-page-feeling fragment updates, layers, and forms. |
| `htmz` | A tiny (roughly one line) approach that targets a hidden iframe; the smallest possible footprint. |
| `alpine` | Alpine.js with its AJAX plugin, for sprinkling behaviour into markup with `x-` attributes. |

All five suit the "handler returns an HTML fragment" model, so the rest of the project, the routes,
handlers, and views, is identical whichever you choose; only `wwwroot/index.html` differs. Single-page
and JSON-first frameworks are deliberately not offered, because they do not match this server-rendered
model. An unrecognised value is rejected with the list of valid ones. You can always change your mind
later by editing `wwwroot/index.html` and swapping the `<script>` tag by hand.

## Cross-compiling a program

Kyte can build a program for a different operating system than the one you are on, because the compiler
carries a cross-capable C++ toolchain for the runtime. Pass a target:

```sh
kyte app.ky --target linux-x86_64   -o app-linux
kyte app.ky --target linux-arm64    -o app-linux-arm64
kyte app.ky --target windows-x86_64 -o app.exe
```

The target names a program build as `<os>-<arch>`. The compiler builds the runtime for that target the
first time it sees it and caches it, then links a real ELF or PE executable. This is a best-effort
convenience for shipping a service built on your development machine; the native target is always the
most exercised.

## WebAssembly (experimental, synchronous subset only)

Kyte can also compile to WebAssembly. This is a best-effort, experimental target meant for pure,
sandboxed computation, not for running a Kyte service. Ask for it with `--target wasm`:

```sh
kyte compute.ky --target wasm
```

If `wasm-ld` (it ships with LLVM) is on your PATH, the compiler links the module for you in one step and
writes it straight to your `-o` path, so `kyte compute.ky --target wasm -o compute.wasm` gives you a
ready `compute.wasm`. If `wasm-ld` is not found, the compiler keeps the freestanding `wasm32` object and
prints the exact link line to run yourself (already aimed at your `-o` path):

```sh
wasm-ld --no-entry --export-all build/debug/obj/compute.wasm.o -o compute.wasm
```

The module needs no host imports for the supported subset. It carries its own small string runtime, so
integers, `long`, `bool`, value structs, control flow, function calls, generics, ARC, string literals,
string concatenation, and number interpolation all lower and run inside a plain wasm host. Export the
functions you want to call by marking them `export fn`.

One ABI note: both `int` and `long` are passed and returned as 64-bit values at the wasm boundary, so a
JavaScript host calls an exported function with `BigInt` arguments (`fib(10n)`, not `fib(10)`). This is
only the calling convention; `int` still behaves as a 32-bit value with wraparound inside the module, so
arithmetic gives the same result it would on a native build.

### `async`/`await` does not compile to WebAssembly

This is the boundary to keep in mind. The asynchronous machinery, `async fn`, `await`, the reactor, and
coroutines, is native-only and does not lower to wasm. An `await` that reaches code generation is
rejected at build time rather than producing a broken module. In practice this means the whole
networking and I/O surface (HTTP, sockets, TLS, the web framework, the database drivers) is not available
on the wasm target, because it is all built on the async reactor.

So treat the wasm target as a way to ship a synchronous, self-contained computation (parsing, encoding, a
pure algorithm, a small library of value transforms) into a wasm host. For anything that awaits, build a
native binary and run it under Kynator as described in Chapter 23.

## Where to go next

- Chapter 17 for the web framework the `--framework` scaffold sets up.
- Chapter 23 for running a built service in production with Kynator.
- Chapter 1 to return to the everyday `kyte` and `kyte test` workflow.
