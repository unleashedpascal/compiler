# Extra Improvements

Smaller, targeted improvements that unlock Pascal patterns standard FPC modes reject. Some are gated on their own modeswitch (enabled by default in `unleashed`); others are `unleashed`-only with no dedicated switch. Each entry states which.

A few features that once lived here now have their own reference pages: [compound assignment and `inc()` / `dec()` on properties](compound-assignment.md), and the [`Type()` intrinsic](type-intrinsic.md). This page keeps the rest.

## String-to-ordinal typecast

Modeswitch `stringordcast` (default in unleashed). Cast a string literal of matching size directly to an ordinal type. The compiler packs the bytes in the target's native endianness into a compile-time constant, so the in-memory byte layout of the result always matches the source byte order. The fold produces an `ordconstn`, usable anywhere a constant is: `const`, `var` initializers, typed constants, inline vars.

```pascal
const
  MZ_SIG    = word('MZ');                  // 2 bytes: 'M' 'Z'
  RIFF_SIG  = dword('RIFF');               // 4 bytes
  MAGIC_64  = qword('abcdefgh');           // 8 bytes
  MAGIC_128 = uint128('0123456789abcdef'); // 16 bytes

var sig := dword('RIFF'); // inline var, inferred
if pdword(@buf[0])^ = RIFF_SIG then ...
```

Supported target types by size:

| Size | Types |
|---|---|
| 1 byte | `Byte`, `ShortInt` |
| 2 bytes | `Word`, `SmallInt` |
| 4 bytes | `LongWord`, `DWord`, `Cardinal`, `LongInt` |
| 8 bytes | `QWord`, `Int64` |
| 16 bytes | `UInt128`, `Int128` |

The source can include `#N`-escaped chars (`dword(#$DE#$AD#$BE#$EF)`, `dword('AB'#$00#$01)`). The length must match the target size exactly, otherwise `Cannot cast string of length N to ordinal type "..."`.

**Native-endian, source-order in memory.** On a little-endian target `dword('abcd')` has numeric value `$64636261`, stored as `61 62 63 64`; on big-endian the numeric value is `$61626364`, also stored as `61 62 63 64`. So a signature check like `pdword(@buffer)^ = dword('RIFF')` works uniformly across platforms.

## Type helpers on any type

Modeswitch `typehelpers` (default in unleashed). `type helper for T` works on any named type, not just classes and records:

```pascal
type
  TIntHelper = type helper for integer
    function timesTwo: integer;
  end;

  TIntArr = type array of integer;
  TIntArrHelper = type helper for TIntArr
    function toString: string;
  end;

var n: integer = 21;
begin
  writeln(n.timesTwo); // 42
end.
```

(Note: `.method` directly on a numeric literal inside a `$'...'` interpolation placeholder confuses the tokenizer - `{21.timesTwo}` reads `21.` as a float. Assign to a variable first, or call outside the placeholder.)

The `record helper for T` spelling extends the same set of types. In unleashed mode (with `typehelpers` active) both spellings declare the same construct, so Delphi-style record helpers on primitive and class types compile unchanged:

```pascal
type
  TIntHelper = record helper for integer
    function timesTwo: integer;
  end;
```

## Multi-helpers

Modeswitch `multihelpers` (default in unleashed). Several helpers for the same type are visible at once (by default only the last one in scope wins). Useful when two units each ship a helper for `integer` and you want methods from both.

## Implicit generics

Modeswitch `implicitgenerics` (default in unleashed and delphi). Enables Delphi-style generic syntax - no `generic` / `specialize` keywords, plain `<T>` in declarations and specializations:

```pascal
{$mode objfpc}
{$modeswitch implicitgenerics}

type
  TList<T> = class
    procedure add(const item: T);
  end;
var l: TList<integer>;
```

**The switch replaces the explicit form, it does not stack on top of it.** With `implicitgenerics` active, `generic` and `specialize` are ordinary identifiers again (exactly as in `{$mode delphi}`), so `generic TList<T> = class` no longer parses - use the plain `TList<T>` form. This is the whole point: one modeswitch buys the Delphi generic surface in any mode. If you need the explicit `generic` / `specialize` keywords, compile that unit in `objfpc` without the switch.

### No type inference at call sites

`implicitgenerics` changes the spelling only. It does **not** infer the type arguments of a generic routine from the actual parameters. A call to a generic function or procedure always names its type arguments in `<...>`; a call without them is an error, regardless of how obvious the type looks:

```pascal
function maxOf<T>(a, b: T): T;
begin
  result := if a > b then a else b;
end;

var d: double = 2.5;

writeln(maxOf<double>(d, 1.5)); // ok
writeln(maxOf(d, 1.5));         // Error: Wrong number of parameters specified for call to "maxOf"
```

The error message talks about the parameter count because without type arguments the compiler looks for a non-generic `maxOf` taking two parameters and finds none.

Inference from arguments is a separate stock modeswitch, `implicitfunctionspecialization`, and unleashed mode leaves it **off**. It infers the type of an integer literal as the smallest signed type that holds it, so the specialization silently computes in that narrow type:

```pascal
{$modeswitch implicitfunctionspecialization} // opt-in, per file

function sumOf<T>(a, b: T): T;
begin
  result := a + b;
end;

writeln(sumOf(100, 100));          // -56: T inferred as ShortInt, the sum wraps
writeln(sumOf<integer>(100, 100)); // 200
```

Enable it per file when that trade-off is acceptable; the explicit `<...>` form keeps working alongside it.

## Helpers for specializations

Unleashed-only, no separate modeswitch. A helper may extend a generic specialization, spelled directly in the helper declaration - no named alias needed:

```pascal
type
  TWrap<T> = record
    val: T;
  end;

  TIntWrapHelper = record helper for TWrap<LongInt>
    procedure Bump;
  end;
```

The helper binds to the specialization itself, so it is found on every equal specialization of the same generic - in the declaring unit and in every unit that uses it. A helper declared for a named alias (`TIntWrap = TWrap<LongInt>`) behaves the same way.

Outside unleashed mode helpers keep their stock behavior: a specialization cannot be spelled directly as the extended type, and a helper declared for an alias is only found on the exact specialization it was declared for, not on equal specializations materialized in other units.

## Nested generic methods

Unleashed-only, no separate modeswitch. Stock FPC rejects a `generic` declared inside another with `Declaration of generic inside another generic is not allowed` - a limitation of its single token-replay buffer, not a language rule. Unleashed lifts it: a generic class or record can declare a method with its own type parameter list, independent of the enclosing type's.

```pascal
type
  TBox<T> = class
    v: T;
    function pair<U>(const b: U): string;
  end;

function TBox<T>.pair<U>(const b: U): string;
begin
  result := Format('T=%d U=%d', [sizeof(T), sizeof(U)]);
end;

var box := TBox<integer>.Create;   // class specialized once: T = integer
writeln(box.pair<byte>(0));        // method specialized here: U = byte
writeln(box.pair<double>(0.0));    // same method, different U
```

The class and the method specialize independently, and the nested template survives PPU serialization, so a generic method declared in one unit specializes correctly when called from another. Nested generic types, constraints on the nested method (`pair<U: class>`), and managed `U` types all work.

Build strings inside a generic body with `Format()`, not `$'...'` interpolation - the interpolation lowering currently miscompiles inside a generic method whose placeholders reference a type parameter.

## Array size shorthand

Unleashed-only, no separate modeswitch. A bare positive integer constant inside `array[...]` is the element count: `array[N] of T` is shorthand for `array[0..N-1] of T`.

```pascal
var
  a: array[10] of integer;       // 0..9, ten elements
  m: array[3, 4] of integer;     // 0..2 by 0..3, twelve elements
  k: array[5, 'a'..'c'] of byte; // shortcut mixes with a char range
```

Multi-dim works through the same comma loop as the long form, so shortcut indices mix freely with explicit ranges and type-indexed dimensions. Memory layout is identical to the explicit form (one contiguous block, row-major), so `Move()`, `FillChar()`, `SizeOf()` see the same flat span. `array[0]` and `array[-N]` are rejected with `Upper bound of range is less than lower bound`.

`string[N]` is **not** affected - it keeps its shortstring meaning (a different parser path). The shortcut fires only inside `array[...]`, and sits next to the existing forms (ranges, type-indexed, dynamic, open, FAM) rather than replacing them.

## Numeric underscores

Modeswitch `underscoreisseparator` (default in unleashed). A `_` between digits in a numeric literal is purely visual - the scanner drops it, the value is unchanged, and it is always optional. Works in every base:

```pascal
var a := 100_000_000;              // decimal
var mask := $FFFFFFFF_FFFFFFFF;    // hex
var flags := %11110000_10101010;   // binary
var perm := &777_000;              // octal
```

Without the switch the underscore is a syntax error mid-literal (`Syntax error, ")" expected but "identifier _000" found`).

Use it sparingly, only to make a genuinely long literal readable - a short number reads fine bare, so `1_000` is noise. When you do group, the grouping is fixed per base: decimal by 3 (thousands) once it reaches 9+ digits, hex by 8 (one 32-bit word) at 9+ digits, binary by 8 (one byte) at 9+ digits, octal by 3 at 10+ digits. Hex and binary group by the storage unit, not by 2 or 4, because a 4-digit hex group like `$FF00_0000` reads worse than the bare `$FF000000`.

## Modeswitch summary

| Modeswitch | Default in unleashed | Feature |
|---|---|---|
| `stringordcast` | on | string-literal cast to an ordinal |
| `typehelpers` | on | `type helper for T` on any named type |
| `multihelpers` | on | several helpers for one type visible at once |
| `implicitgenerics` | on | Delphi-style `<T>` (replaces explicit `generic` / `specialize`) |
| `underscoreisseparator` | on | `_` as a digit-group separator in numeric literals |

Unleashed-only, no switch: nested generic methods, `array[N]` shorthand. To opt into a default-on switch from another mode use `{$modeswitch name}`; to opt out in unleashed use `{$modeswitch name-}`.

## Demo

```pascal
program extra_demo;

{$mode unleashed}

uses SysUtils;

type
  TIntHelper = type helper for integer
    function timesTwo: integer;
  end;

  // nested generic method: class T and method U specialize independently
  TBox<T> = class
    v: T;
    function pair<U>: string;
  end;

function TIntHelper.timesTwo: integer;
begin
  result := self*2;
end;

function TBox<T>.pair<U>: string;
begin
  result := Format('sizeof(T)=%d sizeof(U)=%d', [sizeof(T), sizeof(U)]);
end;

const
  RIFF = dword('RIFF'); // string-to-ordinal fold, native endianness

var
  grid: array[3, 4] of integer; // array[N] shorthand: 0..2 by 0..3
begin
  var n := 21;
  writeln($'n.timesTwo = {n.timesTwo}');
  writeln($'dword(''RIFF'') = ${HexStr(RIFF, 8)}');

  var box := TBox<integer>.Create;
  writeln(box.pair<byte>);
  writeln(box.pair<double>);
  box.Free;

  writeln($'array[3, 4] element count = {length(grid)}x{length(grid[0])}');
  {$ifdef WINDOWS}readln;{$endif}
end.
```

Output:

```
n.timesTwo = 42
dword('RIFF') = $46464952
sizeof(T)=4 sizeof(U)=1
sizeof(T)=4 sizeof(U)=8
array[3, 4] element count = 3x4
```
