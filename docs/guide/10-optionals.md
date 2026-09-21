# 10. Optionals

An **optional** is written `T | undefined`, and there is a shorthand `T?` that means exactly the same
thing. Use whichever reads better: `string?` and `string | undefined` are the same type. The value
`undefined` means **absence**: there is no value here, *not* an error (errors are Chapter 11). Two
standard-library staples return optionals: `List<T>.get(i)` and `Map<K,V>.get(k)` both return
`T | undefined`, because the index or key might not be there.

You get at the value four ways:

- **Coalesce** with `??`: `xs.get(i) ?? default` yields the value if present, otherwise the default.
- **Narrow** with `if (x != undefined) { ... }`: inside the branch, `x` is a plain `T`.
- **Chain** with `?.`: `user?.name` reads `.name` only if `user` is present; if it is `undefined`, the
  whole expression is `undefined`.
- **Return absence** yourself with `return undefined` from a function typed `T | undefined`.

Member access *through* an optional is memory-safe: it is guarded at runtime, never a silent null-deref.

```kyte
// examples/16_optionals.ky
// An optional is `T | undefined`, where `undefined` means ABSENCE (not an
// error). `List<T>.get(i)` and `Map<K,V>.get(k)` return `T | undefined`.
// Narrow with `if (x != undefined) { use(x) }`; coalesce a default with `??`;
// reach through a possibly-absent value with `?.`.
import collections.list;
import collections.map;
import string;

struct User {
    pub name: string,
    pub age: int,
    init(n: string, a: int) { self.name = n; self.age = a; }
}

// A function whose result may be absent: the return type says so.
fn findAdmin(names: List<string>): string | undefined {
    let i = 0;
    while (i < names.size()) {
        let n = names.get(i) ?? "";
        if (n == "root") { return n; }
        i = i + 1;
    }
    return undefined;   // no admin found: absence, not failure
}

fn main(): void {
    // ---- List.get returns T | undefined; unwrap with ?? ----
    let fruits = list.List<string>();
    fruits.push("apple");
    fruits.push("banana");
    console.log(`fruits[0] = ${fruits.get(0) ?? "?"}`);
    console.log(`fruits[9] = ${fruits.get(9) ?? "?"}`);   // out of range -> undefined

    // ---- Map.get returns V | undefined ----
    let ages = map.Map<string, int>(16, string.hash);
    ages.set("ada", 36);
    console.log(`ada     = ${ages.get("ada") ?? -1}`);
    console.log(`babbage = ${ages.get("babbage") ?? -1}`);   // missing key -> undefined

    // ---- Narrowing: inside the guard the value is a plain T ----
    let names = list.List<string>();
    names.push("guest");
    names.push("root");
    let admin = findAdmin(names);
    if (admin != undefined) {
        console.log(`admin found: ${admin}`);
    } else {
        console.log("no admin");
    }

    let noAdmin = findAdmin(fruits);
    if (noAdmin != undefined) {
        console.log(`admin found: ${noAdmin}`);
    } else {
        console.log("no admin");
    }

    // ---- Optional chaining `?.`: reach a field only if present ----
    let users = map.Map<string, User>(16, string.hash);
    users.set("ada", User("Ada", 36));
    // present: `?.` reads the field; absent: the whole expression is undefined,
    // so `??` supplies the fallback.
    console.log(`ada  name = ${users.get("ada")?.name ?? "?"}`);
    console.log(`grace name = ${users.get("grace")?.name ?? "?"}`);
}
```

Output:

```
fruits[0] = apple
fruits[9] = ?
ada     = 36
babbage = -1
admin found: root
no admin
ada  name = Ada
grace name = ?
```

| Form | Meaning |
|------|---------|
| `T \| undefined` | An optional: a `T` or the absence value `undefined` |
| `xs.get(i)` / `m.get(k)` | Returns `T \| undefined` (out of range / missing key gives `undefined`) |
| `x ?? default` | The value if present, else `default` |
| `if (x != undefined) { ... }` | Narrows `x` to `T` inside the branch |
| `x?.field` | `field` if `x` is present, else `undefined` (chains) |
| `return undefined` | Produce absence from a `T \| undefined` function |

`.get(i)` returns an optional; its sibling `.at(i)` returns a present `T` (used when you have already
bounded the index). Reading a field of an *absent* optional is caught: as a compile error where the
checker can see it, and otherwise as a located runtime abort, so an optional never becomes a silent
null-dereference.

## Narrowing across `&&` and `||`

A guard narrows for the rest of the same boolean expression, not just inside an `if` body. Because `&&`
and `||` short-circuit (Chapter 2), a guard on the left protects the right operand:

```kyte
fn f(x: string | undefined): int {
    if (x != undefined && x.length > 0) { return x.length; }  // x is present in `x.length`
    return -1;
}

fn g(x: string | undefined): bool {
    return x == undefined || x.length == 0;   // x is present in `x.length` (the == guard was false)
}
```

The same applies to the branches of an `if`. The then-branch is narrowed by every `!= undefined`
conjunct, and the else-branch by every `== undefined` disjunct:

```kyte
fn both(a: string | undefined, b: string | undefined): int {
    if (a != undefined && b != undefined) {
        return a.length + b.length;    // both a and b are present here
    }
    return -1;
}

fn viaElse(x: string | undefined): int {
    if (x == undefined) { return -1; } else { return x.length; }  // x is present in the else
}
```

An early-exit guard narrows the rest of the function too: after `if (x == undefined) { return 0; }`,
`x` is a plain `T` for everything that follows.

## Optional fields in structs and classes

A field is made optional by giving it an optional type, either `T?` or `T | undefined`. This is how you
say "this value may be missing" on a record, for example a user who has not set an email yet. The field
works exactly like any other optional: read it with `??`, narrow it with `if (x != undefined)`, or reach
through it with `?.`.

In a **struct**, list the field with its optional type and give it a value at construction. A missing
value is written `undefined`; a present value is written directly.

```kyte
struct Box {
    pub a: string?,            // shorthand for `string | undefined`
    pub b: int | undefined,    // the same thing, written out
}

fn main(): void {
    let present = Box { a: "hi", b: 7 };
    let absent  = Box { a: undefined, b: undefined };

    console.log(present.a ?? "?");     // "hi"
    console.log(`${absent.b ?? -1}`);   // -1

    // To narrow, bind the field to a local first: narrowing works on a plain
    // variable, so `if (name != undefined)` makes `name` a present `string`.
    let name = present.a;
    if (name != undefined) {
        console.log(`len = ${name.length}`);
    }
}
```

In a **class**, declare the field the same way and set it in `init`. Because a class is mutable, you can
assign a present value later, and methods read it through `??` just like anywhere else. (Class methods
take an explicit `self: ClassName` first parameter.)

```kyte
class User {
    pub name: string,
    pub email: string?,             // optional field: may be absent
    init(n: string) {
        self.name = n;
        self.email = undefined;     // start with no email
    }
    pub fn label(self: User): string {
        return self.email ?? "no email";
    }
}

fn main(): void {
    let u = User("Ada");
    console.log(u.label());         // "no email"
    u.email = "ada@x.io";           // set a present value later
    console.log(u.label());         // "ada@x.io"
    if (u.email != undefined) {
        console.log("email is set");
    }
}
```

The same forms are what the serialization layer reads and writes: an `@serializable` struct with an
optional field maps a missing JSON key (or a JSON `null`) to `undefined`, and a present key to the value.
See [Serialization](16-serialization.md).

## Coalescing an optional fallback

`a ?? b` gives `a` when it is present, otherwise `b`. When the fallback `b` is itself optional, the whole
expression stays optional, because it can still be absent when both sides are:

```kyte
let a: int? = undefined;
let c: int? = 3;
let r: int? = a ?? c;     // a is absent, so r is c (present 3)

let x: int? = undefined;
let y: int? = undefined;
let z: int? = x ?? y;     // both absent, so z is undefined

// Chained: the first present value wins, else the final default.
let n = a ?? c ?? 7;      // 3
```

When the fallback is a plain (non-optional) value, `a ?? b` unwraps to that plain type, which is the
common case: `list.get(i) ?? 0` is an `int`, not an `int?`.

Next: [Error handling](11-error-handling.md)
