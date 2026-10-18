# Kyte

Kyte is a statically-typed, natively-compiled language for server-side services and hypermedia apps.
Its syntax is ES6/TypeScript-flavored; it compiles through LLVM to a native binary with a C++20 async
runtime and a standard library written in Kyte itself. Linux (x86-64) is the production target; macOS
and Windows are development hosts (Windows builds natively). Kyte compiles to native code only; it does
not target WebAssembly. See [docs/STABILITY.md](docs/STABILITY.md) for the full platform stance.

**Status: 1.0.0 (stable)** on the native target. Kyte follows semantic versioning: within the `1.x`
major version, the language and the runtime ABI are backward compatible, so what compiles and links
today keeps working across `1.x` releases (see [docs/STABILITY.md](docs/STABILITY.md)). Report the
version with `kyte version`.

```kyte
struct Point { pub x: int, pub y: int }

fn dist2(p: Point): int { return p.x * p.x + p.y * p.y; }

fn main(): void {
    let total = 0;
    for (i in 1..=100) { total = total + i; }
    console.log(`sum 1..100 = ${total}`);
    let p = Point { x: 3, y: 4 };
    console.log(`dist2(3,4) = ${dist2(p)}`);
}
```

## What is in this repository

This is the **language implementation**. Three cooperating codebases make up Kyte:

| Component        | Language | Location         | Responsibility                                                                                                      |
| ---------------- | -------- | ---------------- | ------------------------------------------------------------------------------------------------------------------- |
| Compiler         | Zig 0.16 | `src/`           | Lowers Kyte to LLVM IR, then to a linked native executable.                                                         |
| Runtime          | C++20    | `src/runtime/`   | Async scheduler (LLVM coroutines), non-blocking sockets, channels, actors, allocator.                               |
| Standard library | Kyte     | `src/lib/std/`   | Collections, string, JSON/YAML/BSON serde, decimal128, regex, crypto + TLS, the HTTP/web framework, the DB drivers. |

BTreeDB (a Zig storage engine, in a sibling repo) and the database drivers + orchestrator (published
Kyte packages) are **consumers** of the language, not part of it.

## Releases

Prebuilt, self-installing toolchain bundles are attached to each tagged release on the
[releases page](https://github.com/kytelang/kyte/releases). Each bundle contains the `kyte` compiler, the
`kynalyzer` language server, the prebuilt runtime (`libkytecore.a`), and the standard library, with an
`install.sh` that copies the tree into `~/.kyte`:

```bash
tar xzf kyte-1.0.0-<os>-<arch>.tar.gz
cd kyte-1.0.0-<os>-<arch>
./install.sh                # installs to ~/.kyte; then add ~/.kyte/bin to your PATH
kyte version                # -> kyte 1.0.0
```

Verify the download against the accompanying `.sha256` before extracting. Bundles are host-specific: the
compiler links LLVM and compiles the C++ runtime at install time, so each release ships a separate archive
per platform. If a bundle for your platform is not published, build from source below.

## Quick start

Prerequisites: **Zig 0.16.0** and an **LLVM 22** install. The pinned toolchain fetch is scripted:

```bash
export PATH="$(scripts/bootstrap-zig.sh | tail -1):$PATH"     # download + checksum-verify the pinned Zig, add to PATH
export KYTE_LLVM_PREFIX=/path/to/llvm  # e.g. $(brew --prefix llvm@22) on macOS
zig build                              # builds `kyte`, installs to ~/.kyte/bin/kyte
```

Then compile and run a single program:

```bash
kyte hello.ky -o hello && ./hello      # build an executable, then run it
kyte version                           # version + ABI + pinned Zig + host
```

Scaffold a project, then build, run, and test it:

```bash
kyte init web --name myapp             # or: console | desktop
cd myapp
kyte build                             # compile the project to a native binary
kyte run                               # build the project and run it (for a web app, starts the server)
kyte test                              # discover and run the project's tests
```

`kyte run` builds the project (entry `src/main.ky` by default, or pass `--file <path>`) and then executes
the resulting binary in one step, so you do not have to build and launch it separately. `kyte test`
compiles each test case and reports pass or fail per case; run it before and after any change.

Full walkthrough: [docs/guide/01-getting-started.md](docs/guide/01-getting-started.md).

## Documentation map

The guide under [docs/guide/](docs/guide/) is the reference: 26 chapters from the
basics through web, data access, concurrency, and deployment, each grounded in the
conformance corpus.

- [docs/guide/](docs/guide/) -- the language and standard-library guide (start at chapter 01).
- [docs/guide/19-package-management.md](docs/guide/19-package-management.md) -- the package model: `project.json`, `kyte get`, publishing.
- [docs/STABILITY.md](docs/STABILITY.md) -- versioning, the compatibility promise, the platform stance, and the runtime ABI contract.
- [CONTRIBUTING.md](CONTRIBUTING.md) -- building, the gate suite, and how to land a change.
- [CI-POLICY.md](CI-POLICY.md) -- why gating is per-host and what "nothing merges red" means.

## The gate suite (run before and after any change)

```bash
conformance/run.sh -j        # the conformance corpus, parallel (~2 min). AUTHORITATIVE.
conformance/run.sh --shadow  # the soundness gate (ownership-engine agreement + disposition + balance)
conformance/run.sh --asan    # AddressSanitizer gate (needs `KYTE_ASAN=1 zig build` first)
```

Use `-j`. The plain sequential `run.sh` and `--asan` have no per-case timeout and will hang on the
reactor/app cases that wait on a socket; `-j` applies per-case timeouts and is the mode that
terminates. See [CONTRIBUTING.md](CONTRIBUTING.md) for the details.

## License

See the repository root.
