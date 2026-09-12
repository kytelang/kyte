# 1. Getting started

Every Kyte program starts at `fn main(): void`. Printing is done with the built-in `console.log`
(no import required).

```kyte
// examples/01_hello.ky
fn main(): void {
    console.log("Hello, Kyte!");
}
```

Compile it to a native executable and run it:

```sh
kyte docs/guide/examples/01_hello.ky -o /tmp/hello
/tmp/hello
```

```
Hello, Kyte!
```

## The toolchain

| Command | What it does |
|---------|--------------|
| `kyte <file>.ky -o <out>` | Compile one file to a native executable. |
| `kyte build` | Build a project (reads `project.json`). Add `--release` for optimizations. |
| `kyte run [-- <args>]` | Build the project (debug) and run it; args after `--` go to the program. |
| `kyte test <file>.ky` | Compile and run the `@test` functions in a file. |
| `kyte fmt` | Format source. |
| `kyte init console\|web\|desktop --name X` | Scaffold a new project. |
| `kyte get <git-url>` | Add a package dependency (records it in `project.json`, resolves it). |
| `kyte restore` / `kyte update` | Restore locked dependencies / refresh them. |
| `kyte add feature <name>` | Scaffold a new feature slice inside a project. |

Kyte compiles through LLVM to a real native binary; there is no interpreter and no VM. The default
target is your host platform; cross-compilation to another native target is opt-in via `--target`.
Kyte compiles to native code only and does not target WebAssembly. Linux is the production target;
macOS and Windows are development hosts (see [STABILITY](../STABILITY.md)).

## A note on `console`

`console.log`, `console.info`, `console.err`, and `console.debug` are built-ins that print a line. They
accept a string, so use a **template literal** (next chapters) to format other values:

```kyte
let n = 42;
console.log(`the answer is ${n}`);
```

Next: [Values & types](02-values-and-types.md)
