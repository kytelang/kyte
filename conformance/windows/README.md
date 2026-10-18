# Windows-dev smoke tests

Windows is a **development host** for Kyte, not the production target (Linux is;
see [docs/STABILITY.md](../../docs/STABILITY.md)). These programs are a small
smoke check of the Windows build and runtime: a basic arithmetic/string test,
file IO, and directory operations.

They are not part of the default `conformance/run.sh` gate. Run them explicitly
with `conformance/windows/run.sh` when you change anything that could affect the
Windows target:

- **On a Windows host** (MSYS/MinGW/Cygwin) the runner compiles each program for
  the host and runs it, gating exit 0.
- **On any other host** it cross-compiles each to a `windows-x86_64` PE and gates
  that a valid PE is produced. The binary can only be executed on Windows, but
  the cross build catches most regressions.
