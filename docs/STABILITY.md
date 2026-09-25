# Stability and the compatibility promise

This page is the contract between Kyte and the code you write against it: what we
promise not to break, what we reserve the right to change, and which platforms
that promise covers. Report the version you are on with `kyte version`.

## Versioning

Kyte uses semantic versioning of the form `MAJOR.MINOR.PATCH`.

- **Pre-1.0 (`0.x`)**: there is no cross-version stability guarantee. Any release
  may change syntax, standard-library APIs, or the runtime ABI. Pin an exact
  compiler version for anything you intend to keep building.
- **1.0 and later**: the guarantees below apply. Within a major version, a
  program that builds and passes its tests on `1.x` keeps building and behaving
  on any later `1.y` (`y >= x`). Breaking changes wait for the next major
  version and are listed in the changelog with a migration note.
- **Patch releases (`1.x.z`)**: bug fixes and performance work only. No syntax,
  API, or ABI change.

## What the 1.0 promise covers

1. **Language syntax and semantics.** Every construct exercised by the
   conformance corpus (`conformance/cases`, `conformance/expect_fail`) is part of
   the promise. A program that compiles on `1.x` compiles on `1.y >= 1.x`. The
   corpus is the executable specification: if behaviour and the corpus disagree,
   the corpus wins.
2. **The standard-library API.** Public (`pub`) names in the standard library
   keep their signatures and observable behaviour within a major version. Names
   that are not `pub` are internal and may change at any time.
3. **The runtime ABI.** The object-header layout, the ARC entry points
   (`kyte_retain`/`kyte_release` and friends), and the calling convention the
   compiler emits against are stable within a major version, so an object file
   built by one `1.x` links against the runtime of any other `1.x`. `kyte version`
   prints the ABI tag.

## What is explicitly NOT covered

- Anything not marked `pub` in the standard library.
- The exact text of diagnostics, log lines, and `--verbose` output.
- Internal file layouts under `~/.kyte`, compiler intermediate files, and the
  contents of the build cache.
- Performance numbers (we try only to improve them).
- Behaviour outside the supported platforms below.

## Supported platforms

Kyte's platform stance is deliberately narrow so the promise means something.

- **Linux (x86-64) is the only production target.** The runtime is
  run-verified there and that is where the 1.0 guarantee applies.
- **macOS (arm64) and Windows (x86-64) are development hosts.** You can build and
  run Kyte on them to develop and test, and `kyte` compiles a real native binary
  on each. Windows builds natively (no WSL or cross-compile shim is required to
  produce a `.exe`); its runtime is exercised in development but Linux is the
  target we certify for production.
- **WebAssembly is not a target.** Earlier previews described WASM as a secondary,
  best-effort target. That is dropped. Kyte compiles to native code only.

## Sharp edges to know about

These are intentional design choices, called out so they do not surprise you.

- **`int` is a 32-bit signed integer with silent wraparound.** Arithmetic that
  overflows 32 bits wraps rather than trapping or widening. Use `long` (64-bit)
  for counters, sizes, timestamps, database identity columns, byte offsets, and
  anything that can exceed roughly two billion. This is the single most common
  correctness trap for newcomers: when in doubt about range, reach for `long`.
- **Optional early-exit narrowing is limited.** Narrowing an optional inside an
  `if (x != undefined) { ... }` block works and is the recommended form. The
  early-exit shape, `if (x == undefined) { return; }` followed by a use of `x` in
  the tail, does NOT narrow `x` for the code after the `if`. It stays
  memory-safe (a use through the still-optional value aborts at runtime rather
  than reading through a bad value), but the compiler will not treat `x` as
  present. Prefer the positive form `if (x != undefined) { use(x); }`, or bind
  the unwrapped value with `??` where a default makes sense.

## Reporting a break

If a program that built on one `1.x` stops building or changes behaviour on a
later `1.x`, that is a bug in Kyte, not in your code. File it with the output of
`kyte version` and the smallest program that shows the difference. See
[CONTRIBUTING.md](../CONTRIBUTING.md) for how the gate suite is run and how a fix
lands.
