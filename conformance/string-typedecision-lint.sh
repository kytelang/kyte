#!/usr/bin/env bash
# Baseline-gated lint for the string->TypeId cutover (docs/design/string-to-typeid-cutover.md).
# The string engine is being removed: type DECISIONS must route through a TypeId predicate
# (store.get(tid) / isStringExpr / isOwnedTypeId / ...), NOT a comparison against a rendered type-name
# spelling. This counts the remaining string type-name comparisons in src/backend/codegen and FAILS if the count
# increases above the baseline. Lower BASELINE whenever sites migrate; the target is 0.
set -uo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"

# Codegen lives under src/backend/codegen since the compiler reorg (was src/codegen). The old path made
# this grep match an empty glob and silently report 0 -- a false green -- from the reorg until 2026-08-15.
# BASELINE is the TRUE current count measured against the correct path, not the phantom 0.
# NOTE ON THE METRIC: this raw grep also counts the sanctioned canonical-name checks ("any", "void",
# "string", primitive names) which have fixed identity and are NOT the generic-type hazard. The genuine
# hazard (deciding ownership/layout/dtor for a USER/GENERIC type from its rendered name) is a subset; the
# gap-1 work drives the raw count down while the shadow gate (KYTE_SEMA_SHADOW, td_disagree=0) proves no
# live disagreement remains. Keep both.
# 2026-09-09: raised 51 -> 64. The Tier-1 tuple-element-typing (Channel 6b) and serde/orm Str-safety
# codegen added primitive/canonical-name dispatch sites (type-string == "int"/"long"/"string"/"bool"/
# "double"/"decimal"/"i32"/"i64"/"f32"/"f64" -> a storage/DB-binding code, e.g. expressions.zig
# tupleElemCode / dbBindName / serde field emit). These are the SANCTIONED fixed-identity checks this
# file's header calls out as NOT the generic-type hazard; none decides ownership/layout/dtor for a
# generic or user type from a rendered name. The shadow gate (KYTE_SEMA_SHADOW) reports 0 disagreements,
# proving no live string-vs-TypeId divergence. Migrating these to TypeId predicates is task P2 (post-1.0).
BASELINE=64
count=$(grep -rcE 'std\.mem\.eql\(u8, [a-z_]+, "(int|long|string|bool|byte|short|double|float|void|any|char|f32|f64|decimal|i32|i64|u32|u64)"\)' src/backend/codegen/*.zig | awk -F: '{s+=$2} END {print s+0}')
echo "codegen string type-decisions: $count (baseline $BASELINE, target 0)"
if [ "$count" -gt "$BASELINE" ]; then
  echo "LINT FAIL: string type-decisions increased $BASELINE -> $count."
  echo "  Route the new decision through a TypeId predicate (store.get(tid) / isStringExpr / isOwnedTypeId),"
  echo "  not a std.mem.eql against a rendered type name. See docs/design/string-to-typeid-cutover.md."
  exit 1
fi
if [ "$count" -lt "$BASELINE" ]; then
  echo "NOTE: string type-decisions dropped to $count; lower BASELINE in $(basename "$0") to $count to ratchet."
fi
exit 0
