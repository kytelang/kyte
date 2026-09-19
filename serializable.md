# @serializable: injected to/from methods — design and impact

Status: design proposal. Not yet implemented.

## 1. Why

Today a struct marked `@serializable` gets a set of compiler-generated
serialisation functions, but the developer reaches them through free functions and
a two-step "parse then bind" dance. The common cases read awkwardly:

```kyte
// serialise a DTO to a JSON response body
return response.raw(Note__toJson(note));

// load typed config from a YAML file
let cfg = AppConfig__bind(source.fromYaml(rawText));
```

The proposal is to inject ordinary methods on `@serializable` types so the same
work reads as:

```kyte
return response.raw(note.toJson());
let cfg = AppConfig.from(.yaml, rawText);
```

This is a developer-experience change only. It does not change what serialisation
does, only how it is spelled at the call site. The generated machinery underneath
stays exactly where it is.

## 2. How serialisation works today

### 2.1 The intrinsics

`serde.bind<T>`, `serde.dump<T>`, `serde.bindRow<T>`, `serde.bindAll<T>` and
`serde.bindWire<T>` are not library functions. They are compiler intrinsics,
special-cased in `src/backend/codegen/expressions.zig` (around lines 3905 to 4023).
Each call is lowered to a mangled, per-type symbol:

| Intrinsic            | Lowers to        | Purpose                                   |
| -------------------- | ---------------- | ----------------------------------------- |
| `serde.dump<T>`      | `T__dump`        | struct to a `ValueSink` (write side)      |
| `serde.bind<T>`      | `T__bind`        | a `ValueSource` to a struct (read side)   |
| `serde.bindRow<T>`   | `T__bindRow`     | one DB row to a struct                    |
| `serde.bindAll<T>`   | `T__bindAll`     | a result set to a list of structs         |
| `serde.bindWire<T>`  | `T__bindWire`    | raw wire rows to structs                  |
| (to-JSON helper)     | `T__toJson`      | struct to a JSON string                   |

### 2.2 The generator

`generateSerdeBinders` in `src/pipeline.zig` (around line 1136) walks every
`@serializable` struct and emits these `T__*` functions as Kyte source, which is
then compiled like any other code. This is the same "manufacture source, feed it
back through the front end" approach used for a few other generated surfaces.

### 2.3 The read and write plumbing

The generated functions do not hard-code any format. They ride two traits in
`src/lib/std/serde/source.ky`:

- `ValueSource` (line 26): `getString`, `getStr`, `getInt`, `getBool`, `getFloat`,
  `getDecimal`, `getChild`, `has`, `arrayLen`, `item*`. A parser implements this so
  a struct can be filled from it.
- `ValueSink` (line 56): `putString`, `putInt`, `putBool`, `putFloat`, `putDecimal`
  and friends. A writer implements this so a struct can be poured into it.

Concrete sources today: `JsonSource`, `YamlSource` (both in the serde package),
and `DocSource` in the mongodb driver. The BSON side of the serde package
(`src/lib/std/serde/bson.ky`) is write-only: it has `entryString`, `entryInt`,
`entryDoc` and so on, but there is no from-BSON `ValueSource`. Mongodb had to write
its own `DocSource` for reads.

### 2.4 What developers actually type

The generated `T__*` names are consumed inside the compiler and stdlib, never by
hand. Application code hits serialisation through a small number of surfaces:

- Input deserialise is hidden behind `ctx.bind<T>()` in web handlers. Developers
  rarely call `serde.bind` directly.
- DB row and result-set binding is pure generated glue behind `orm.queryAs<T>`,
  `orm.bindAll<T>` / `orm.bindOne<T>` (`src/lib/std/data/orm.ky`, around lines 158
  and 167, which call `serde.bindWire` / `serde.bindRow`).
- The genuinely hand-typed, ugly spots are two:
  1. Output serialise: `Note__toJson(note)` in JSON response paths.
  2. Config load: `source.fromYaml(rawText)` followed by a `__bind`.

Those two are what the new methods clean up. Everything else is already ergonomic
or already hidden.

## 3. Proposed API

Two shapes were considered.

### 3.1 Six named methods

```kyte
note.toJson()          // : string
note.toYaml()          // : string
note.toBson()          // : bytes
Note.fromJson(text)    // : Note
Note.fromYaml(text)    // : Note
Note.fromBson(bytes)   // : Note
```

Reads best at each call site, autocompletes cleanly (typing `note.to` surfaces all
three with correct return types), and each method can grow format-specific options
later (`toJson(pretty)`). Costs: no way to choose the format at runtime without a
manual switch, and six injected symbols per type.

### 3.2 Format enum, two methods

```kyte
enum Format { json, yaml, bson }

note.to(.json)            // runtime-selectable format
Note.from(.json, data)
```

Smaller surface (two injected symbols per type), trivially extensible to new
formats, and, most importantly, lets the format be a value. That last point is the
real win for a web language: content negotiation becomes one line.

```kyte
return response.raw(note.to(req.acceptsFormat()));
```

The catch is the return and input type split. Text formats (json, yaml) are
naturally `string`; bson is `bytes`. A single `to(fmt)` has one return type. The
clean resolution is to unify the core on `bytes` and add a text convenience:

```kyte
fn to(self, fmt: Format): bytes           // the general, runtime-selectable core
static fn from(fmt: Format, data: bytes): T
fn toStr(self, fmt: Format): string       // json/yaml; errors on a binary-only format
```

This is the Go `Marshal` model (everything is bytes) with a thin string helper for
the dominant JSON/YAML path.

### 3.3 Recommendation

Offer the format-enum core (`to`/`from` on `bytes`) plus `toStr(fmt)`, because
content negotiation is a first-class kyte use case and the enum is the only shape
that serves it without a hand-written switch. If we would rather optimise the
common single-format call site over the negotiated one, the six named methods are
the safer, more discoverable default. Both are viable; this is the one open
product decision (see section 8).

Whichever shape wins, the new methods are strictly additive sugar over the existing
free functions. See section 6.

## 4. Injection mechanism

Model the injection on the destructor manufacturer in
`src/backend/codegen/arc.zig` (`getOrCreate...DestructorByTypeId`), which is the
closest existing precedent for "codegen synthesises a per-type function":

- TypeId-driven: one manufactured function per `@serializable` TypeId, created on
  demand and cached, exactly like destructors.
- Field walk with `substituteFieldType` so generic structs specialise correctly.
- Fail-closed: if a field type cannot be resolved to a serialisable shape, refuse
  at compile time rather than emit something that silently drops data. The
  destructor path already does this for unresolved fields.

There are two ways to wire the body:

- (a) Thin methods that delegate to the existing `generateSerdeBinders` output. For
  example `toJson` calls the existing `T__toJson`; `from(.yaml, s)` builds a
  `YamlSource` and calls the existing `T__bind`. This is the least risky path: the
  proven binders stay, the methods are a naming layer.
- (b) Fully manufactured bodies emitted as IR the way destructors are. More work,
  and it duplicates logic that `generateSerdeBinders` already has correct.

Recommendation: start with (a). It gets the DX win with almost no risk, because the
serialisation logic is unchanged. Only move to (b) if we later want to drop the
source-gen step entirely.

The methods need a small runtime helper surface to construct the format sources and
sinks (`kyte_json_*`, `kyte_yaml_*`, `kyte_bson_*`) so `from(.json, s)` can obtain a
`JsonSource` without the developer importing `serde.source`. For the text formats
these wrap the existing `JsonSource` / `YamlSource`. For BSON, new work is needed
(section 7).

## 5. Impact analysis

Findings from a full sweep of the scaffold templates, the example apps, and every
`kyte-*` driver package.

### 5.1 Scaffold and examples (kyte repo)

- The web mediator and dispatcher generators (`src/pipeline.zig`, from around line
  1621) and the ORM codegen (`src/backend/codegen/expressions.zig`, lines 3905 to
  4015) both consume `__bind`, `__bindRow`, `__bindAll`, `__bindWire` and `__toJson`
  by exact name. This is the decisive constraint: the injected methods must be
  additive over the existing free-function names. A rename would break the mediator
  and ORM codegen.
- Real developer-facing serde call sites are fewer than they look. Input
  deserialise is already behind `ctx.bind<T>()`; DB binds are generated glue. The
  hand-typed spots that the new methods improve are output serialise
  (`T__toJson(x)` in JSON response paths) and config load (`source.fromYaml(...)`).
- No behaviour change for scaffolds: existing templates keep compiling untouched.
  We would, in a follow-up, update the scaffolds and example apps to use the nicer
  methods so new users see the good idiom by default.

### 5.2 Drivers

Serialisation is an app-layer concern for five of the six driver packages.

- kyte-postgres, kyte-mysql, kyte-mssql, kyte-kaidb: no `@serializable`, no serde
  intrinsics. They expose raw wire rows and result sets; the stdlib ORM does the
  typed binding above the driver boundary. Unaffected by this change.
- kyte-datastar: uses only the low-level `serde.json` value builder
  (`json.stringify` over a hand-built `JsonValue`), which is unrelated to
  `@serializable` struct injection. Unaffected.
- kyte-mongodb: the one coupled package. It calls `serde.dump<T>` (DTO to BSON on
  insert, `src/mongodb.ky:1245`) and `serde.bind<T>` (fetched doc to struct,
  `src/mongodb.ky:1254` and `:1261`), and implements both traits itself
  (`MongoSink impl ValueSink` and `DocSource impl ValueSource` in
  `src/document.ky`, around lines 108 and 124). It references the intrinsic surface
  and the traits, never the mangled `T__*` names.

### 5.3 Verdict

Adding injected methods, and switching generation to the arc.zig-style codegen
path, is additive and safe for every driver, mongodb included, provided two things
stay stable:

1. the `serde.dump<T>` / `serde.bind<T>` intrinsics, and
2. the `ValueSink` / `ValueSource` trait method signatures.

The only way to force a mongodb change is to remove or rename those intrinsics or
alter the trait shapes. Keep them stable and no driver needs any change.

## 6. Compatibility constraints (must hold)

1. Additive only. The `T__bind*` and `T__toJson` free functions and their exact
   names must remain, because the mediator, dispatcher and ORM codegen resolve them
   by name. New methods sit on top; they do not replace.
2. Keep the intrinsics and traits stable. `serde.dump<T>`, `serde.bind<T>`,
   `ValueSink`, `ValueSource` are the driver-facing contract (mongodb depends on
   them). Do not reshape them as part of this work.
3. Preserve mongodb's BSON semantics if a `to(.bson)` path ever subsumes its
   hand-written sink:
   - Mongodb deliberately emits int64 (`putInt` to `entryInt64Val`) where the SQL
     `BsonSink` emits int32 (`src/document.ky`, lines 106 to 112). A generic
     `to(.bson)` must not silently narrow to int32 for Mongo documents.
   - Mongodb resolves `serde.dump` / `serde.bind` synchronously, outside any async
     frame, on purpose (comments at `src/mongodb.ky:1241` and `:1250`). A hidden
     sink inside a method must not drag serialisation into an async frame.
   Simplest safe stance: the format-enum `to(.bson)` targets the stdlib BSON sink;
   mongodb keeps its explicit `MongoSink` / `DocSource` and is not asked to route
   through the new method. Revisit only if we want one BSON path.

## 7. New work required

- from-BSON `ValueSource`. `serde.bson` is write-only today, so `from(.bson, ...)`
  has nothing to read from. Either add a `BsonSource` to the serde package, or, for
  a first cut, ship json and yaml only and leave bson to the mongodb-owned path.
- Runtime helper surface (`kyte_json_*`, `kyte_yaml_*`, `kyte_bson_*`) so the
  injected methods can build sources and sinks without the developer importing
  `serde.source`.
- If we adopt `toStr(fmt)`: a fail path for calling it on a binary-only format
  (bson). Recommend a compile-time or clear runtime error, not a silent lossy
  conversion.

## 8. Open decisions

1. API shape: six named methods, or the format-enum core plus `toStr`. Section 3.3
   leans enum for content negotiation; this is a product call.
2. Error model for the from side: return `T?` (optional, caller handles the miss)
   or raise an `exception` on malformed input. Should match how `ctx.bind<T>()`
   already behaves so the two do not diverge.
3. toBson return type: `bytes` (a full BSON document) is the natural answer under
   the unified-on-bytes design. Confirm no caller wants a `BsonDocument` handle
   instead.
4. Collision policy: if a user hand-writes a method named `toJson` on a
   `@serializable` type, the user method must win and injection must skip that name.
   Decide and document this before shipping.
5. Scope of the first cut: json and yaml only (leaving bson to mongodb), or all
   three from the start (which pulls in the from-BSON source work).

## 9. Suggested rollout

1. Land the injected methods as thin sugar over the existing binders (mechanism
   4(a)), json and yaml only, format-enum shape, `to`/`from`/`toStr`. No driver
   touched, no intrinsic changed.
2. Update scaffolds and example apps to use the methods, so new projects show the
   good idiom.
3. Add the from-BSON `ValueSource` and extend `.bson` support, keeping mongodb's
   int64 and synchronous constraints in mind.
4. Only if warranted, migrate generation from source-gen to fully manufactured IR
   (mechanism 4(b)).

## 10. As built (first cut, shipped)

The first slice is implemented and gated (conformance case `13_serde.ky`). It
deviates from the proposal above in three places, each forced by Kyte's actual
inventory. This section is authoritative for what exists today; sections 1 to 9 are
the design record.

### 10.1 Surface

A `Format` enum lives in `src/lib/std/serde/source.ky`:

```kyte
pub enum Format { json, yaml, bson }
```

Every `@serializable` struct gets two methods injected:

```kyte
note.to(Format.json)            // instance method,  : string
Note.from(Format.json, body)    // static method,    : Note
Note.from(Format.yaml, text)    // static method,    : Note
```

Working cells today: `to(Format.json)`, `from(Format.json, ...)`,
`from(Format.yaml, ...)`. The rest are wired but inert: `to` with `yaml`/`bson`
returns `""`, and `from` with `bson` returns a default-constructed value. They are
placeholders until a YAML sink and a from-BSON `ValueSource` land (sections 3.2, 7).

### 10.2 Three deviations from the proposal

1. `to` returns `string`, not `bytes`. There is no ergonomic owned byte-buffer value
   type in Kyte (`bytes` is a low-level pointer module; there is no `RawBuffer`/`Buffer`
   value struct), and the natural serialised outputs are `string` (json/yaml) and
   `bson.BsonDocument` (bson). So `toStr` from the proposal is redundant and was
   dropped; `to(fmt): string` is the serialise method. A future `toBson(): BsonDocument`
   can cover the binary format on its own return type.
2. No `.json` shorthand. Kyte has no leading-dot inferred-enum literal, so the call
   syntax is `Format.json`, not `.json`. `Format` resolves unqualified in any
   `@serializable` module because such a module always loads `serde.source` (its
   `ValueSource` type is used by the unconditionally-generated binder).
3. `from` on an unsupported format returns a default value rather than raising. Kyte
   enforces exhaustive enum `switch`, so the generated bodies use a `default:` arm.
   This keeps the "total, never fails" contract that `ValueSource` already follows.

### 10.3 Mechanism (as implemented)

Not the arc.zig IR route. In `generateSerdeBinders` (`src/pipeline.zig`), after the
free-function binders are emitted and parsed, a second pass generates a tiny source
snippet per struct (`fn to(self: S, fmt: Format)...`, `fn from(fmt: Format, data: string)...`),
parses it as `<serde-methods>`, and splices the resulting `FunctionDecl`s into that
struct's `StructDecl.methods` as `MethodDecl`s (`from` with `is_static = true`,
detected by the absence of a `self` first parameter). This reuses the proven binders
and needs zero import injection, because `serde.source` (which itself imports
`serde.yaml`/`serde.json` and defines `fromJson`/`fromYaml`) is already loaded for
every serializable module.

Collision policy (decided, implemented): a user-defined method named `to` or `from`
on the struct wins; injection skips that name and leaves the user's method intact.
Generic structs (`type_params.len != 0`) are skipped, since the bare `T__bind` /
`T__toJson` names would not resolve against per-instantiation mangling.

### 10.4 Not yet done

- `to(Format.yaml)`: needs a YAML `ValueSink` plus a struct-to-YAML writer (there is
  no `T__dumpYaml` and no YAML sink today).
- `from(Format.bson, ...)` and `to(Format.bson)`: need a from-BSON `ValueSource` and
  a decision on the BSON return type, honouring mongodb's int64 and synchronous
  constraints (section 6).
- Migrating existing hand-typed call sites and the scaffold/example apps to the new
  methods. They already compile unchanged; this is cosmetic follow-up.
