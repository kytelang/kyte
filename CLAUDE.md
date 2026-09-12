# CLAUDE.md - Kyte language implementation

## What this is

Kyte is a statically-typed, natively-compiled language for server-side services and hypermedia apps:
the compiler is written in Zig 0.16, the runtime in C++20, and the standard library in Kyte itself. It
compiles through LLVM 22 to a native executable. Status is 1.0.0 (stable), native target only, no
WebAssembly. This repo is the language implementation; see [README.md](README.md) for the overview and
[docs/STABILITY.md](docs/STABILITY.md) for the platform and compatibility stance.

## Build

Prerequisites: Zig 0.16.0 (pinned) and an LLVM 22 install.

```bash
export PATH="$(scripts/bootstrap-zig.sh | tail -1):$PATH"   # download + checksum-verify the pinned Zig
export KYTE_LLVM_PREFIX=/path/to/llvm                       # e.g. $(brew --prefix llvm@22) on macOS
zig build -Doptimize=ReleaseFast                            # builds kyte, installs to ~/.kyte/bin/kyte
```

Build `ReleaseFast` for anything you will actually run: a Debug compiler is roughly 100x slower and looks
like a hang (every corpus case hits its timeout). On macOS the installed binaries are unsigned and the
kernel may SIGKILL them; if a freshly built `kyte` dies immediately, re-sign it with
`codesign --force --sign - ~/.kyte/bin/kyte`.

## The gate suite (authoritative: run before AND after any change)

`gate.sh` is the full host gate (build, conformance, dogfood, fuzz smoke, shadow/OSSA/reachability). CI is
per-host because the native toolchain cannot build on hosted runners, and nothing merges red
(see [CI-POLICY.md](CI-POLICY.md)). The pieces you run most often:

```bash
conformance/run.sh -j        # conformance corpus, parallel (~2 min). AUTHORITATIVE executable spec.
conformance/run.sh --shadow  # soundness gate: string vs TypeId ownership engines must agree
conformance/run.sh --arc     # per-case ARC leak gate (baseline-gated)
KYTE_ASAN=1 zig build && conformance/run.sh --asan   # AddressSanitizer (needs the sanitized build first)
zig build test               # compiler + stdlib unit tests
./gate.sh                    # the whole host gate, exits non-zero on any failure
```

Always use `-j`. The plain sequential `run.sh` and `--asan` have NO per-case timeout and will hang on the
reactor/app cases that wait on a socket; `-j` applies per-case timeouts and is the mode that terminates.
Every behaviour change needs a conformance case: a positive case under `conformance/cases`, or an
`EXPECT-FAIL` case under `conformance/expect_fail`. If code and corpus disagree, the corpus wins.

## Working in this repo (how to make a change)

1. **Understand, then plan.** Read the relevant `src/` module and the conformance cases that exercise it
   before editing. Keep the change minimal and match the surrounding Zig style and the existing module
   patterns; do not reformat or restructure unrelated code.
2. **Verify behaviour, not just compilation.** Build `ReleaseFast` and drive the real path: write a small
   `.ky` program that hits your change, compile and run it, and confirm the output. "It compiles" is not
   done.
3. **Run the gate before and after.** At minimum `conformance/run.sh -j` and `--shadow`. Add `--asan`
   (sanitized build first) for anything touching codegen, ARC, or the runtime. Run `./gate.sh` before you
   consider a change finished.
4. **Add a conformance case for every behaviour change** (positive under `conformance/cases`, or
   `EXPECT-FAIL` under `conformance/expect_fail`). The corpus is the executable spec.
5. **Keep the soundness gates green.** Type decisions flow through `TypeId`, not name strings, and the
   shadow gate must agree. For ARC or ownership bugs, the opt-in verifiers help: `KYTE_OSSA=1` runs the
   balance verifier and `KYTE_OWN_VERIFY=1` runs the use-after-move checker.
6. **Recovering a broken build:** prefer `git stash` over `git reset --hard` (a hard reset can discard
   generated or uncommitted work), then re-run `zig build` to regenerate artifacts.
7. **Commit only when asked**; if you are on `main`, branch first. The LSP, orchestrator, and drivers are
   separate repos (see Ecosystem): a change to any of those does not belong here.

## Layout map

- `src/frontend/` - lexer, parser, `sema/` (ownership, mono, reach, shadow, OSSA), `type_checker.zig`.
- `src/backend/codegen/` - LLVM IR codegen (`llvm_codegen.zig`) and ARC insertion (`arc.zig`); `linker/` wraps in-process LLD.
- `src/lib/std/` - the standard library in Kyte: collections, str, serde (JSON/YAML/BSON), crypto + TLS, net, web, data (drivers/ORM).
- `src/runtime/` - the C++20 runtime: self-hosted async reactor, sockets, channels, actors, allocator, crypto (`kyte_abi.h` is the ABI header).

## Conventions and gotchas

- Build `ReleaseFast` for anything perf-sensitive; a Debug compiler is ~100x slower.
- On macOS, codesign installed binaries if they get SIGKILLed (see Build above).
- Runtime and ABI symbols are `kyte_*` (for example `kyte_retain` / `kyte_release`); the ABI is stable within `1.x`.
- The runtime is a self-hosted kqueue/epoll/IOCP reactor. There is no Boost.Asio dependency.
- Prose follows Indian English with British spellings (behaviour, colour, initialise) and no em dashes; never change code identifiers or API names (`serialize`, `color`, `initialize`) to match.
- 1.x source and runtime-ABI stability is a promise: see [docs/STABILITY.md](docs/STABILITY.md). `int` is 32-bit with silent wraparound; reach for `long` for anything past ~2 billion.

## Ecosystem context

This repository is the language only. The tooling and libraries that consume Kyte live in separate sibling
repos and ship as git-URL packages (manifest `project.json`, lockfile `project.lock.json`, no central
registry; see [docs/guide/19-package-management.md](docs/guide/19-package-management.md)):

- kynalyzer - the language server (LSP).
- kynator - the orchestrator.
- the database drivers - kyte-postgres, kyte-mysql, kyte-mssql, kyte-mongodb.
- kyte-datastar and kyte-web - the hypermedia and web packages.
