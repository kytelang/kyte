# Guide examples

These are the runnable code snippets for the Kyte guide, not standalone apps. The numbered files
(`01_hello.ky` through `30_web_middleware.ky`) line up with the guide chapters in `docs/guide/`, and the
chapters link to them by relative path, so keep them here beside the prose they illustrate. The
subfolders (`webapp`, `fd-handoff`, `tls`) and helper scripts (`run-live.sh`) back specific chapters too.

Run the whole set with `run_all.sh`: it compiles and runs every `*.ky` here (files with `@test` go through
`kyte test`, the rest are compiled and executed), reporting pass or fail. That doubles as a check that the
guide's code still builds against the current toolchain.

For complete, clone-and-run sample applications (a full project with `project.json`, `src/`, and `tests/`),
see the top-level [`examples/`](../../../examples) directory instead.
