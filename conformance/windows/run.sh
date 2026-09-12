#!/usr/bin/env bash
# Windows-dev smoke gate. Windows is a development host for Kyte (Linux is the
# production target; see docs/STABILITY.md), so these are not part of the default
# `conformance/run.sh` gate. Run this explicitly when you touch anything that
# could affect the Windows build or runtime.
#
# On a Windows host (MSYS/MinGW/Cygwin, or OS=Windows_NT) it compiles each program
# for the host and RUNS it, gating exit 0. On any other host it cross-compiles
# each to a windows-x86_64 PE and gates that a valid PE is produced (a real
# executable can only be run on Windows, but the cross build catches most
# regressions). Exits non-zero on any failure.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
KYTE="${KYTE:-$HOME/.kyte/bin/kyte}"

is_windows=0
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*) is_windows=1 ;;
esac
[[ "${OS:-}" == "Windows_NT" ]] && is_windows=1

fail=0
for f in "$HERE"/t*.ky; do
  name="$(basename "$f")"
  out="$(mktemp -t kytewin.XXXXXX)"; out="$out.exe"
  if [[ $is_windows -eq 1 ]]; then
    if "$KYTE" "$f" -o "$out" >/dev/null 2>&1 && "$out" >/dev/null 2>&1; then
      echo "  PASS  $name (built + ran)"
    else
      echo "  FAIL  $name (build or run failed)"; fail=1
    fi
  else
    "$KYTE" "$f" --target windows-x86_64 -o "$out" >/dev/null 2>&1
    magic="$(head -c2 "$out" 2>/dev/null)"
    if [[ "$magic" == "MZ" ]]; then
      echo "  PASS  $name (cross-built a PE; run on Windows to execute)"
    else
      echo "  FAIL  $name (windows cross-build produced no PE)"; fail=1
    fi
  fi
  rm -f "$out" "$out.o" 2>/dev/null
done

if [[ $fail -ne 0 ]]; then echo "Windows smoke gate FAILED"; exit 1; fi
echo "Windows smoke gate passed"
