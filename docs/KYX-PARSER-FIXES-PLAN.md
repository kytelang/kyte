# KYX parser and rendering fixes

Status: implemented (commit on `enhancement-one`; corpus 470/470). All four bugs fixed via the
raw-text reconstruction plus the `\u{...}` decode and located KYX errors described below. Owner:
Kyte language. Raised from building the Varman (ACP) console in KYX,
where four KYX behaviours forced ugly workarounds. All four are genuine language bugs and are worth
fixing regardless of the console, because they make KYX unsafe for ordinary human-readable copy
(emoji, apostrophes, entities, and normal spacing between words and inline tags).

## Background: the KYX pipeline

- Lexer: `src/frontend/lexer.zig` (`nextToken` switch begins at line 337; the char-class fallthrough
  `else` arm is at 635-640).
- Parser: `src/frontend/parser.zig` (`parseJsxElement` at 2857-3010; the text-child coalescing loop at
  2982-2999; the documented "single space where not physically adjacent" note at 2866-2868).
- Codegen: `src/backend/codegen/expressions.zig` (`emitJsxInto` around 6964-7075; static text is emitted
  raw at 7037 via `jsxAppendLiteral`; dynamic `{expr}` string children are escaped at 6087-6108 through
  `kyte_html_escape`).
- Runtime escape: `src/runtime/core.cpp` `kyte_html_escape` (834-869), mirrored in the stdlib at
  `src/lib/std/web/response.ky` `escapeHtmlInto` (54-71) and `escapeHtmlIntoView` (77+).
- String escape decoding: `src/backend/codegen/llvm_codegen.zig` `unescapeString` (139-165).
- Tests: no standalone `.kyx` fixtures; KYX is exercised through `.ky` conformance cases under
  `conformance/cases/` (run by `conformance/run.sh`, gated by `gate.sh:27`). The escaping case to extend
  is `conformance/cases/442_kyx_escaping_always_on.ky`.

## Root cause (shared by bugs 1, 2, 4)

Inside KYX element text, the general expression lexer runs unchanged. That lexer:
- strips any byte it does not recognise (the `else` arm at lexer.zig:635-640 prints
  `Unexpected character` and advances one byte, dropping emoji, non-ASCII and `#`),
- treats `'` as a char-literal opener (lexer.zig:616-634), so an apostrophe in copy swallows text,
- and the parser reconstructs text from tokens with a single synthetic space between tokens
  (parser.zig:2982-2999), which both collapses real spacing and cannot see boundary whitespace.

So `<span>Don't ship &#128187;</span>` is mangled three ways at once: the `'` opens a char literal,
the `#` and the emoji bytes are dropped, and the words are re-spaced by token position.

The clean fix is a **KYX raw-text lexer mode**: when the parser is reading the text content of a KYX
element (between `>` and the next `<`, `{` or `}`), the lexer should return the raw source span verbatim
as a single text token, preserving every byte and all interior whitespace, and stopping only at `<`,
`{` or `}`. That single change removes bugs 1, 2 (text half) and 4, and makes bug 3 tractable because
the raw span already carries the correct leading and trailing whitespace.

The two remaining pieces are independent small fixes: `\u{...}` decoding in string literals (bug 2
second half), and inter-node whitespace when a text run abuts an element or `{expr}` (bug 3).

Below, each bug is described with its tactical fix as well, in case the team prefers targeted patches
over the raw-text mode. The recommendation is the raw-text mode plus the two small fixes.

---

## Bug 1: HTML entities in KYX text are broken

Symptom: `&#128187;` typed as KYX text renders as literal "& 128187;" (a laptop emoji was intended).

Cause: static KYX text is emitted raw by codegen (expressions.zig:7037), so the entity is not
`&`-escaped there. The damage is done in the lexer: `#` hits the unexpected-character arm
(lexer.zig:635-640) and is dropped, and the surrounding `&` and digits are re-spaced by the text
coalescer (bug 3). For dynamic `{expr}` children, a separate hazard exists: `kyte_html_escape`
(core.cpp:846,860 and response.ky:62,85) escapes every `&` to `&amp;` with no entity awareness, so an
`{expr}` that yields `"&#128187;"` becomes `"&amp;#128187;"`.

Fix:
- Primary: the raw-text lexer mode preserves `&#128187;` byte for byte in static text. Done.
- Optional and lower priority: do not make `kyte_html_escape` entity-aware. Keeping `&` to `&amp;`
  unconditional in the escape path is the correct XSS-safe default. Authors who want a literal entity
  from an expression should use the existing raw/`Html`-typed path (case `443_kyx_html_type.ky`). Note
  this in the docs rather than weakening the escaper.

Acceptance:
- `<span>&#128187; &#9881; &amp;</span>` renders exactly `💻 ⚙ &amp;` (the numeric entities decode in
  the browser; the bare `&` still escapes to `&amp;`).
- A new conformance assertion in `442_kyx_escaping_always_on.ky` checks that a numeric entity in static
  text survives to the output unchanged (`&#128187;`), and that a bare `&` still becomes `&amp;`.

---

## Bug 2: emoji and non-ASCII stripped; `\u{...}` not decoded

Symptom: an emoji glyph in KYX text prints `Unexpected character` and vanishes; `{"\u{1F4BB}"}` renders
the literal text `\u{1F4BB}`.

Cause, two halves:
- Text half: the lexer `else` arm at lexer.zig:635-640 drops any byte >= 0x80, so all UTF-8
  continuation bytes of an emoji are lost.
- Escape half: `unescapeString` (llvm_codegen.zig:139-165) has cases for `n r t \ " '` but no `u` case,
  so `\u{...}` falls to the `else` at 153-156 and is emitted verbatim.

Fix:
- Text half: the raw-text lexer mode passes emoji and all non-ASCII through untouched. Separately, even
  outside KYX the `else` arm should not silently drop bytes; at minimum it should carry the byte into a
  token or raise a located error, not `std.debug.print` and continue. Preserving UTF-8 in identifiers
  and string literals is the correct behaviour.
- Escape half: add a `'u'` case to `unescapeString` that parses `\u{HEX}` (1 to 6 hex digits), validates
  the scalar, and appends its UTF-8 encoding. Mirror the same in `readString` if it participates in
  escape handling (lexer.zig:831-848 currently treats `\` as skip-two, so decoding stays in
  `unescapeString`; confirm the two agree).

Acceptance:
- `<div>💻 flight ✈</div>` renders the emoji intact, no `Unexpected character` on stderr.
- `{"\u{1F4BB}"}` and `{"caf\u{00e9}"}` render `💻` and `café`.
- New conformance cases assert both (emoji-in-text, and `\u{}` decoding in a string literal).

---

## Bug 3: whitespace around `{expr}` and inline elements is collapsed

Symptom: `foo <span>x</span> bar` renders `fooxbar`; `label {value} unit` renders `labelvalueunit`.

Cause: parser.zig:2982-2999 only synthesises a single space BETWEEN two text tokens inside one run,
and breaks on `.less`, `.jsx_close`, `.left_brace`, `.greater` without emitting any boundary space. The
sibling `.element` branch (2957-2959) and `{expr}` branches (2960-2980) append children with no
inter-node whitespace. Source whitespace was already consumed by `skipWhitespace`, so nothing remains
to reconstruct at boundaries.

Fix:
- With the raw-text lexer mode, a text run keeps its own leading and trailing spaces verbatim, so
  `foo <span>` keeps the space before `<span>` and `</span> bar` keeps the space after. This is the
  correct and simplest fix: preserve source whitespace in text spans rather than re-synthesise it.
- If the raw-text mode is not adopted, the tactical patch is: in the text coalescer, when the run is
  ended by `.less`, `.left_brace` etc., check whether the source column of the terminator is greater
  than the end column of the last text token and, if so, append a trailing space; likewise a leading
  space when a text run starts at a column past the previous node. This is fiddlier and still loses
  runs of multiple spaces, so the raw-text mode is preferred.

Acceptance:
- `foo <span>x</span> bar` renders `foo x bar`.
- `{a} and {b}` renders `<a> and <b>` with both spaces.
- `allow {n}` and `{n} decisions` render `allow 5` and `5 decisions`.
- New conformance cases assert inter-node spacing for text-element-text and text-expr-text.

---

## Bug 4: an apostrophe in KYX text crashes the parser with no line number

Symptom: `<p>Don't ship</p>` fails with a bare "Parser error" and no location.

Cause: the lexer treats `'` unconditionally as a char-literal opener (lexer.zig:616-634): it scans to
the next `'` or EOF, swallowing element text, then the parser's text loop (parser.zig:2986-2998) never
sees a normal token and a downstream `expect`/`UnexpectedToken` returns without a line.

Fix:
- Primary: the raw-text lexer mode never enters char-literal scanning inside KYX text, so `'` is just a
  byte in the text span.
- Independent hardening: parser errors from `parseJsxElement` should always carry a token line and
  column. Whatever `expect`/`UnexpectedToken` path fires here should include the current token's
  position so a future KYX error is locatable. This is worth doing on its own for author ergonomics.

Acceptance:
- `<p>Don't ship the user's data</p>` compiles and renders with the apostrophes intact.
- Any KYX parse error reports a file, line and column (add a deliberately malformed KYX conformance
  case and assert the error carries a location).

---

## Suggested sequencing

1. Add the KYX raw-text lexer mode (parser signals the lexer to read a raw text span until `<`, `{`,
   `}`; lexer returns one text token with bytes and whitespace preserved). This resolves bugs 1, 2
   (text), 3 and 4 together. Highest value, one focused change in lexer plus parser text handling.
2. Add the `\u{...}` case to `unescapeString` (bug 2 escape half). Small and independent.
3. Ensure `parseJsxElement` errors carry a location (bug 4 ergonomics). Small and independent.
4. Extend `conformance/cases/442_kyx_escaping_always_on.ky` and add new cases for emoji, `\u{}`,
   inter-node whitespace, apostrophes, and located parse errors. Wire nothing new into `gate.sh`; the
   existing conformance runner picks up new cases.

## Risks and notes

- The raw-text mode must NOT change attribute parsing or `{expr}`/`<child>` handling; it applies only to
  the character data between a `>` and the next `<`, `{` or `}`. Keep the datastar attribute raw-pass
  behaviour (case `444`/`468`) unchanged.
- Do not weaken `kyte_html_escape`. The XSS-safety of escaping `&<>"'` on dynamic string children is
  correct; entity and emoji ergonomics come from the raw-text path and `\u{}` decoding, not from
  relaxing the escaper.
- After the fix, the ACP console workarounds (iconless card headers, `{" "}` spacer expressions,
  apostrophe-free copy) become unnecessary; that console is being replaced by a Vue app, but the same
  fixes benefit any future KYX UI.
