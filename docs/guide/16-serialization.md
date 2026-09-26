# 16. Serialization

Turning structs into JSON and back is a compile-time feature in Kyte, not a runtime reflection trick.
Annotate a struct with **`@serializable`** and the compiler generates two free functions for it:

- **`<Struct>__bind(src: ValueSource): Struct`**: deserialize from a `ValueSource`. It recurses into
  nested `@serializable` structs and over `List<T>` fields automatically.
- **`<Struct>__toJson(value: Struct): string`**: serialize back to a JSON string, in
  field-declaration order. `__toJson` is symmetric with `__bind`, so a value round-trips.

On top of these it also injects two convenience methods, `value.to(fmt)` and `Struct.from(fmt, data)`,
which most code uses in preference to calling the binders by name (see [The `to` and `from`
methods](#the-to-and-from-methods) below).

A `ValueSource` is the abstract input the binder reads. `serde.source.fromJson(raw)` wraps a raw JSON
string as one. (The same abstraction is what lets a web handler bind a struct from a request whose fields
come partly from the route and partly from the body: same generated `__bind`, different source.)

One requirement: an `@serializable` struct must have a zero-argument `init()` that sets defaults for
every field. `__bind` starts from those defaults and overwrites whatever it finds in the source, so a
missing key keeps its default instead of crashing.

```kyte
// examples/23_serde.ky
// Marking a struct `@serializable` makes the COMPILER generate binders for it at
// compile time: no reflection, no hand-written parsing:
//
//   * `<Struct>__bind(src: ValueSource)` : deserialize from a source (here JSON),
//     recursively over nested structs and List<T> fields.
//   * `<Struct>__toJson(value)`          : serialize back to a JSON string, in
//     field-declaration order (symmetric with __bind).
//
// `serde.source.fromJson(raw)` wraps a raw JSON string as a ValueSource that the
// generated binder reads. Every @serializable struct needs a zero-arg `init()`
// that sets defaults; __bind overwrites the fields it finds.
import serde.source;
import list;

@serializable
struct Address {
    pub street: string,
    pub city: string,
    init() { self.street = ""; self.city = ""; }
}

@serializable
struct User {
    pub id: long,
    pub name: string,
    pub active: bool,
    pub address: Address,      // nested @serializable struct
    pub roles: List<string>,   // List of primitives
    init() {
        self.id = 0;
        self.name = "";
        self.active = false;
        self.address = Address();
        self.roles = List<string>();
    }
}

fn main(): void {
    let raw = "{\"id\":7,\"name\":\"Ada\",\"active\":true," +
              "\"address\":{\"street\":\"Main\",\"city\":\"Pune\"}," +
              "\"roles\":[\"admin\",\"dev\"]}";

    // Parse JSON into User via the compiler-generated binder.
    let u = User__bind(source.fromJson(raw));
    console.log(`id      = ${u.id}`);
    console.log(`name    = ${u.name}`);
    console.log(`active  = ${u.active}`);
    console.log(`city    = ${u.address.city}`);
    console.log(`#roles  = ${u.roles.size()}`);
    let i = 0;
    while (i < u.roles.size()) {
        console.log(`  role[${i}] = ${u.roles.at(i)}`);
        i = i + 1;
    }

    // Serialise User to JSON via the compiler-generated writer (round-trips).
    console.log(`json    = ${User__toJson(u)}`);
}
```

Output:

```
id      = 7
name    = Ada
active  = true
city    = Pune
#roles  = 2
  role[0] = admin
  role[1] = dev
json    = {"id":7,"name":"Ada","active":true,"address":{"street":"Main","city":"Pune"},"roles":["admin","dev"]}
```

| Piece | Role |
|-------|------|
| `@serializable` | Ask the compiler to generate binders for this struct |
| `init()` (zero-arg) | Required; supplies field defaults `__bind` starts from |
| `<Struct>__bind(src)` | Deserialize from a `ValueSource` (recursive over structs + `List<T>`) |
| `serde.source.fromJson(raw)` | Wrap a raw JSON string as a `ValueSource` |
| `<Struct>__toJson(value)` | Serialize back to JSON, field-declaration order |

## The `to` and `from` methods

The `__bind` / `__toJson` free functions are the engine, but you rarely need to call them by name. For
every `@serializable` struct the compiler also injects two ergonomic methods that read more naturally at
the call site:

- **`value.to(fmt: Format): string`**: serialize this value to a string in the given format.
- **`Struct.from(fmt: Format, data: string): Struct`**: build a value of the struct from a string in the
  given format. This is a static method, so you call it on the type, not an instance.

`Format` is a small enum in `serde.source` with `json`, `yaml`, and `bson`. Today `to(Format.json)` and
`from(Format.json, ...)` are the fully wired pair, and `from(Format.yaml, ...)` also works (it reads YAML
through the same binder). The remaining cells are placeholders until the matching reader or writer lands:
`to(Format.yaml)` and `to(Format.bson)` return an empty string, and `from(Format.bson, ...)` returns a
default value. So they are safe to call but only JSON (and YAML for `from`) does real work right now.

```kyte
import serde.source;   // brings `Format` into scope

let u = User { id: 7, name: "Ada", active: true, address: Address(), roles: List<string>() };

// Serialize, then rebuild. `to`/`from` are sugar over the generated binders:
//   u.to(Format.json)            == User__toJson(u)
//   User.from(Format.json, s)    == User__bind(source.fromJson(s))
//   User.from(Format.yaml, s)    == User__bind(source.fromYaml(s))
let s = u.to(Format.json);
let back = User.from(Format.json, s);      // round-trips
let fromYaml = User.from(Format.yaml, "id: 7\nname: Ada\n");
```

Two things to know:

- The methods are added only when you have not written your own. If you declare a method named `to` or
  `from` on the struct yourself, the compiler leaves it alone and skips injecting that one, so your
  version always wins.
- Generic `@serializable` structs (those with type parameters) do not get the `to`/`from` methods,
  because the binder names are mangled per instantiation. Use the `__bind` / `__toJson` free-function
  path for those.

As with the fields the binders read, the struct's fields must be `pub` for the generated methods to reach
them across the module boundary where the binders are emitted.

## Why compile-time

Because the binders are generated from the struct's declared fields, there is no runtime type
information and no schema to keep in sync by hand: change a field and the binder changes with it at the
next build. Note the round-trip in the output: the final `json` line is exactly the input re-emitted in
field order, which is what makes `__toJson` and `__bind` a matched pair.

Next: [Building a web service](17-web.md)
