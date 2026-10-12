# `$embedstr` / `$embedbytes` Directives

Embed the contents of a file into the source at compile time - the asset ships inside the binary, with no runtime file I/O and no external resource to lose. Two directives, one per output type:

- **`$embedstr`** - the file becomes a `String`.
- **`$embedbytes`** - the file becomes an `array of byte`.

Both read the file as raw bytes and emit the encoded data at the directive site. They are directives, not modeswitches - always available regardless of `{$mode}`.

The name `embed` (rather than `include`) is deliberate: `{$include}` / `{$i}` splice another file in as *source code to be compiled*, whereas these directives bake a file in as *data*.

## Two forms each

Each directive has a 2-arg and a 1-arg form, chosen by token count: two tokens (`NAME 'path'`) emit a named constant, one token (`'path'`) emits a bare value expression.

```pascal
{$embedstr   NAME 'path'}   // const NAME: String = '...';
{$embedstr   'path'}        // bare String expression
{$embedbytes NAME 'path'}   // const NAME: array[0..N-1] of byte = (...);
{$embedbytes 'path'}        // bare [$xx,$yy,...] array literal
```

The path may be quoted with `'...'` or `"..."`, or left bare (no spaces inside). Path resolution matches `{$I}`:

- an **absolute** path is used verbatim;
- a **relative** path is searched in the current source file's directory, then the local includepath, then the global includepath;
- a name starting with `*` stands for the current source file, so `'*.dat'` inside `unit1.pas` means `unit1.dat` (same rule as `{$R *.res}`).

## `$embedstr`

For a non-empty file, the 2-arg form emits a `const` whose initializer is the file bytes as concatenated Pascal string fragments:

```pascal
const <name>: String =
'<printable run 1>'+#$nn+#$nn+'<printable run 2>'
+'<printable run 3>'+...;
```

The 1-arg form emits just the expression (no `const`, no `;`), usable anywhere a `String` value fits. Bytes are classified at encode time:

- printable ASCII (`$20..$7E` except the apostrophe) goes into single-quoted runs;
- everything else (control bytes, high-bit bytes, the apostrophe) becomes a `#$nn` escape (`#$n` for single-nibble values).

Empty file: the 2-arg form emits `const <name>: String = '';`, the 1-arg form emits `''`.

After compilation the constant is a `String` whose bytes match the file byte for byte: `length(schema)` is the file size, `byte(schema[i])` is byte `i-1` of the original.

## `$embedbytes`

The 2-arg form emits a typed `const` with a parenthesized initializer (standard Pascal array-init syntax, so the emitted const compiles in every mode):

```pascal
const <name>: array[0..N-1] of byte =
($a,$bb,$4,$5,
$6,$7,$8);
```

The 1-arg form emits a bare array literal in square brackets: `[$a,$bb,$4,...]`. The bracket difference mirrors how Pascal parses constructors per context: `(...)` is the typed-const initializer, `[...]` is the inline array constructor used in expressions, which resolves to `array of byte` automatically when the surrounding context expects one.

Empty file: 2-arg emits `const <name>: array of byte = ();`, 1-arg emits `[]`. Bytes are emitted in compact hex (`$X` for `0..$F`, `$XX` otherwise), broken across lines at about 64 characters.

```pascal
procedure sendFrame(const bytes: array of byte);
begin
  stream.Write(bytes[0], length(bytes));
end;

begin
  sendFrame({$embedbytes 'frame.bin'}); // 1-arg, inline
end.
```

### Pitfall: typed-const init takes `(...)`, not `[...]`

```pascal
const data: array of byte = {$embedbytes 'data.bin'}; // does NOT compile
```

Pascal's typed-const initializer parses `(...)`, not the `[...]` the 1-arg form emits. Use the 2-arg form for named byte arrays: `{$embedbytes data 'data.bin'}`.

### Pitfall: `var x := {$embedbytes ...}` infers `array of LongInt`

```pascal
var x := {$embedbytes 'data.bin'}; // x is array of LongInt, NOT array of byte
```

The 1-arg form is a bare `[$xx,...]` literal, and inline-var inference picks the default integer type (`LongInt`) for integer-literal elements regardless of value range. Symptom: `length(x)` is right but each element is 4 bytes, so `move(x[0], dest, length(x))` copies only every fourth byte of what you meant. Pin the type instead:

```pascal
{$embedbytes data 'path'}                            // 2-arg: array[0..N-1] of byte
var x: array of byte := {$embedbytes 'data.bin'};    // explicit annotation
foo({$embedbytes 'data.bin'});                       // a byte-array parameter pins it
```

## Use cases

- Baking small fixed assets (icons, fonts, schemas, templates) into a single-binary executable.
- Compiled-in default configuration that always exists as a fallback.
- Lookup tables produced by an external tool, picked up at the next build without a generated `.pas` file.
- Byte-exact test fixtures - compile-time embedding rules out "file missing at run time".

Use `$embedstr` when the consumer wants text or a buffer to `move()` out of; `$embedbytes` when an API demands `array of byte` typing (binary protocols, hash inputs, decoder feed).

## Constraints and notes

- **2-arg forms** expand to a `const` declaration, so they must sit where a const declaration is valid: at unit / program scope (after `uses`), or anywhere a local `const` is accepted in unleashed mode.
- **1-arg forms** expand to a bare expression and must sit where a value of the matching type fits (argument, comparison operand, right-hand side). No named binding - to reference the same data twice, use the 2-arg form.
- The data is baked in at the directive site; repointing the file requires recompilation.
- Large files inflate compile time (the constant still travels through the parser); keep embedded assets reasonably small.

## Errors

| Trigger | Diagnostic |
|---|---|
| `{$embedstr}` / `{$embedbytes}` with no arguments | `Error: embedstr: missing arguments` / `Error: embedbytes: missing arguments` |
| File not found or not openable | `Fatal: Cannot open include file "<path>"` |

A bare `{$embedstr foo}` is read as the 1-arg form looking for a file named `foo`; if no such file exists, the same fatal `Cannot open include file "foo"` fires.

## Demo

With two asset files next to the source - `banner.txt` containing the text `hello from inside the binary` (28 bytes, no trailing newline) and `palette.bin` containing the four raw bytes `$01 $02 $03 $FF`:

```pascal
program embed_demo;

{$mode unleashed}

{$embedstr banner 'banner.txt'}
{$embedbytes palette 'palette.bin'}

begin
  writeln(banner);
  writeln($'banner is {length(banner)} bytes');

  var sum := 0;
  for var b in palette do sum += b;
  writeln($'palette: {length(palette)} bytes, sum {sum}');

  // 1-arg form: inline value, no named constant
  writeln({$embedstr 'banner.txt'});
  {$ifdef WINDOWS}readln;{$endif}
end.
```

Output:

```
hello from inside the binary
banner is 28 bytes
palette: 4 bytes, sum 261
hello from inside the binary
```
