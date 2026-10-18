# Pending negative tests (checks that SHOULD fail but don't yet)

These document real soundness gaps. Each snippet **currently compiles** but *should* be a
compile error. When the check lands, move the snippet into `expect_fail/` as a real `.ky`
case with an `// EXPECT-FAIL: typecheck` directive - the harness then verifies it is rejected
**for that reason**.

Do NOT put these in `expect_fail/` yet - they'd make the harness red (they compile).

> **Audited 2026-07-17.** Every claim below was re-verified by running it. Three entries were
> stale (documented as pending/blocked while actually enforced) and one - return-type - was the
> reverse: documented DONE while **silently regressed**. Do not trust this file without a run;
> that is exactly how the regression survived. See `docs/beta-readiness-plan.md` §0.

---

## ✅ DONE - enforced, verified 2026-07-17

- **Generic instantiation arity mismatch** → `generic_arity_mismatch.ky`
- **Type args on a non-generic type** → `type_args_on_non_generic.ky`
- **Duplicate type parameter names** → `duplicate_type_param.ky`
- **Condition must be boolean** → `non_bool_condition.ky`
- **Assignment (let-init) type mismatch** - `isTypeCompatible` is numeric⇄numeric only.
- **Argument count mismatch** → `wrong_arg_count.ky`. *(Was documented "BLOCKED on namespaced
  resolution"; that is **stale** - F1 stage 3a's ambiguity-is-an-error check unblocked it and it
  now rejects with no stdlib false positives. Verified by running PENDING's own snippet.)*
- **Constructor arg count** → `constructor_arg_count.ky`
- **Narrowing / signedness / ptr truncation / int literal overflow / decimal** → their own cases.
- **Return type mismatch** → `return_type_mismatch.ky`.
  ⚠️ **This check REGRESSED and was repaired 2026-07-17.** `checkReturnType` exempted *every* int
  literal (`if (intLiteralValue(value) != null) return;`) so that `return 4000000000` from a `uint`
  fn could adapt - but the exemption was unconditional, so **`fn f(): string { return 42; }`
  compiled and segfaulted**. The exemption is now gated on the declared return being numeric.
  The harness could not see the regression because it judged negative cases on exit code alone and
  **a segfault also exits non-zero**; it now asserts the *reason*.

---

## Optional narrowing - RESOLVED at runtime (P2-14, 2026-07-17); compile-time enforcement still pending

✅ **The live SEGFAULT is FIXED.** `let s = l.get(5); let n = s.length;` on an absent optional
used to read through address 0 and SEGV. It now ABORTS with
`member access on an absent optional at <file>:<line>` - codegen guards a member deref whose
object is optional-typed (specs §3.4, gated by `cases/38_optional_deref_guard.ky`; corpus
ASAN-clean). See-through ergonomics (`xs.get(i).field`, commit 950495c) are kept; the guard is a
no-op on present values.

**✅ COMPILE-TIME rejection LANDED.** Using an optional where a `T` is required is now a type error,
not a runtime trap: assigning it to a `T`, passing it as a `T` argument, and returning it from a `T`
function are all rejected with a "make it present first" diagnostic.

```kyte
let s: string | undefined = "hi";
let x: string = s;                 // ERROR: possibly-undefined assigned to 'string'
let n = takes(s);                  // ERROR: possibly-undefined passed as 'string'
fn f(): string { return s; }       // ERROR: returning possibly-undefined as 'string'
```

**✅ Flow-narrowing LANDED too** (`462_shortcircuit_and_narrowing.ky`). `x` is narrowed to present in:
the then-branch of `if (x != undefined)`, the else-branch of `if (x == undefined)`, after an
early-exit guard (`if (x == undefined) return;`), and across `&&` / `||` short-circuits
(`x != undefined && x.length`, `x == undefined || x.length`, and their multi-guard chains). The last
of these was made SOUND by implementing real short-circuit evaluation for `&&`/`||` in codegen (they
used to evaluate BOTH operands and bitwise-combine, so `false && f()` called `f()` and a guarded
deref ran on the absent path). See infer.zig (`collectTrueNarrowings`/`collectFalseNarrowings`) and
expressions.zig (the `.And`/`.Or` short-circuit blocks).

## ✅ Tuple element typing + binary-operand type check - LANDED

Tuple destructuring now registers each binding with its element type: `let (v, e) = divide(10, 2)`
gives `v: int` and `e: string`, so `let x: int = e` and `let s: string = v` are both rejected.

The remaining half - a binary operator on incompatible operands, which the tuple case surfaced
(`v * e` where `v` is int and `e` is string) - is now caught by the operand-type check in
`checkExpr`'s `.binary` arm (`binOpCatsCompatible`), gated to `expect_fail/binary_operand_type_mismatch.ky`.
`int - string`, `int * bool`, `5 == "x"`, `int && bool` and the like are type errors. `+` with a string
operand stays valid because it is concatenation (`"n=" + 5`), and the resolver's `.other` types (structs,
traits, enums, bare-call returns it cannot trust) are left alone to avoid false positives. Full corpus
stayed green.

Tuple arity is also enforced now: `let (a, b, c) = divide(1, 1)` (3 names from a 2-tuple) and
`fn bad(): (int, string) { return (1, "x", 42); }` (3-tuple from a 2-tuple signature) are both rejected.
The whole tuple section here is resolved.

Also **not** a type-checker issue but recorded here because it is the same feature: every tuple
leaks its box and elements (`28_tuple_return_heap` = 68 live, `29_http_request_parse` = 46 - see
`arc-baseline.txt`), and `return t` via a local is a **use-after-free** (the retain guard is
syntactic on `v.kind == .tuple`, so it only fires for a tuple *literal* in return position).
Full detail: `docs/route-handling-via-mediator.md` §8.D.

## ✅ Null-coalesce present-path type reinterpret (`opt ?? Fallback().field`) - CHECK LANDED 2026-09-03

Now enforced: `expect_fail/null_coalesce_scalar_reinterpret.ky`. The type checker rejects a
`??` whose unwrapped-present type and fallback type are a scalar-vs-heap-aggregate mismatch (the
pointer-as-scalar reinterpret shape), e.g. `Box | undefined ?? int`, with a diagnostic that also
points at the usual cause: `.field`/`.method()` binding to the FALLBACK
(`opt ?? fb().field` parses as `opt ?? (fb().field)`; parenthesise as `(opt ?? fb()).field`).

The guard (`type_checker.zig`, `nullish_coalesce` case in `resolveExprType` +
`isScalarReinterpretMismatch`) is deliberately narrow to avoid false positives from the
best-effort resolver: it fires ONLY on scalar<->heap-aggregate pairs (numeric<->numeric,
text<->text, trait<->struct are all left alone), and ONLY when the left operand is resolved
through a reliable path (`leftTypeIsReliableForNc` excludes bare-name free-function calls, whose
flat by-name table mis-resolves `parse(x)` across modules). Full corpus stayed 444/444.

## Private field access from outside the struct (F1 stage 4)
```kyte
struct Secret { hidden: i32, init() { self.hidden = 5; } }
@test
fn t(): void {
    let s = Secret();
    let v = s.hidden;          // ERROR: 'hidden' is private (compiles today)
}
```
Enforcing it will break stdlib code - size that in F1 stage 4 (`F1-name-resolution.md` §6 Q3).

## ✅ Four "crash instead of diagnose" cases - RESOLVED
`undefined_variable`, `undefined_function`, `method_shadowed_by_global_fn`, `ambiguous_bare_call` now
emit proper located diagnostics ("undefined identifier ...", "call to '...' is ambiguous ...", etc.)
rather than an unhandled Zig error + stack trace. Their directives are `typecheck` (three) and
`codegen` (method_shadowed_by_global_fn), and the harness verifies the rejection kind.
