# Inline Variables

Declare variables at the point of first use, with type inference, block scoping, and inline `const`. **This is the default way to declare locals** in Unleashed Pascal - a classic `var` section is the exception, not the rule.

Modeswitch: `inlinevars`, enabled by default in `{$mode unleashed}`. Elsewhere:

```pascal
{$mode objfpc}
{$modeswitch inlinevars}
```

## `=` vs `:=` - hard rule

The two initializer operators apply to disjoint contexts. There is no overlap and the wrong one is a syntax error every time:

| Context | Initializer | Type inference |
|---|---|---|
| classic `var` section (before `begin`) | `=` | not available - type is mandatory |
| typed `const` | `=` | not available |
| inline `var` (inside `begin..end`, for-header, `with var`) | `:=` | available (omit the type) |

```pascal
var x: integer = 42;      // classic section: = required
begin
  var y: integer := 42;   // inline: := required
  var z := 42;            // inline inferred: LongInt
end;
```

## Declaring inline vars

```pascal
// explicit type, with or without an initializer
var x: integer;
var y: integer := 42;

// aggregate initializer for a static array / record (typed-constant syntax)
var a: array[1..3] of string := ('foo', 'bar', 'baz');
var p: record x, y: integer; end := (x: 7; y: 9);

// type inference
var n := 42;       // LongInt
var s := 'hello';  // AnsiString
var f := 3.14;     // Double
var b := true;     // Boolean
```

### Promotion

Sub-32-bit integers infer `LongInt`, char literals infer the default string type - so a temp does not silently land in a narrow range. An explicit cast bypasses it:

```pascal
var x := 200;         // LongInt
var by := Byte(200);  // Byte
```

Only a char **literal** is promoted. A char-typed expression already has a definite type and keeps it: a string index, a `Char` variable, `Chr()`, a function returning `Char` all infer `Char`, so set tests and `case` work on the inferred variable:

```pascal
var s := 'abc1';
var c := 'a';         // AnsiString
var d := s[1];        // Char
var e := Chr(65);     // Char
if d in ['a'..'z'] then writeln('letter');
```

### Array literal inference

A bare `[...]` on the right of an inferred `var` builds a **dynamic array** (`array of T`). `T` is decided by the **first element**:

| First element | Inferred element type |
|---|---|
| string / char literal | `AnsiString` |
| integer literal | `LongInt` |
| float literal | `Double` |
| boolean literal | `Boolean` |
| enum / class / pointer | itself |
| `nil` | `Pointer` |

```pascal
var ints := [1, 2, 1_000_000];        // array of LongInt
var names := ['ada', 'bob', 'carol']; // array of AnsiString
var flags := [true, false];           // array of Boolean
var empty := [];                      // array of AnsiString (hint)
```

Every later element must be assignable to `T`; a mismatch is a compile error (`['aaa', 1]` reports `Incompatible types: got "ShortInt" expected "AnsiString"`). For mixed bags use `array of Variant` explicitly.

**Caveat - integer literals infer `LongInt` by category, not by value.** `var big := [5000000000, 1]` infers `array of LongInt` and **truncates** `5000000000` to `705032704` - the only trace is a compile-time range-check warning. When a bare-literal array must hold values past `LongInt`, pin the type: `var big: array of int64 := [5000000000, 1];`. (The `for var n in [...]` path is different - it widens to fit every element; see below.)

## For-loop variables

```pascal
for var i := 0 to 9 do writeln(i);       // i: LongInt (from the bound)
for var ch in 'hello' do writeln(ch);    // ch: Char
for var s in ['abc', 'longer'] do        // s: AnsiString (every element kept fully)
  writeln(s);
```

An `Int64` counter (explicit or inferred) works on 32-bit targets too - for loops lower to while loops, so the 64-bit arithmetic is ordinary codegen.

### Integer literal lists: set vs array

For an integer `for..in` list the loop variable infers a type wide enough for **every** element, and what it iterates over depends on the values:

- all elements fit `0..255`: the literal stays a **set** (stock Pascal) - ascending iteration, duplicates are a compile error;
- any element is outside `0..255`: it iterates as an **array** - source order, duplicates allowed, no truncation, including `Int64` values.

```pascal
for var n in [3, 1, 2] do write(n, ' ');        // set: 1 2 3
for var n in [4, 1994, 3888] do write(n, ' ');  // array: 4 1994 3888
for var n in [5000000000, 1] do write(n, ' ');  // array: 5000000000 1 (Int64)
```

## Scoping

A nested `begin..end` limits visibility to that block; the outermost block of a routine is not nested, so vars there have routine-wide scope (like a `var` section). For-loop vars are scoped to the loop body.

```pascal
begin
  var inner := 10; // visible only in this block
end;
// inner not visible here

for var i := 0 to 9 do writeln(i);
// i not visible here
```

**No shadowing of routine locals.** An inline var cannot hide a variable, parameter, or `var`-section entry of the enclosing routine - a nested block that redeclares one is a `Duplicate identifier` error. (A unit / program global may be shadowed by a block var, since it is a different scope level.)

### Fresh value on every pass

A declaration with an initializer assigns on every pass, and a managed-type declaration without one (string, dynamic array, interface, managed record) is re-initialized to its default at the declaration point - a loop body never sees the previous iteration's value:

```pascal
for var round := 1 to 3 do begin
  var acc: array of integer;   // empty again each iteration
  acc := acc + [round];
  writeln(length(acc));        // 1, 1, 1
end;
```

An unmanaged declaration without an initializer (`var x: integer;`) stays undefined until assigned, as usual.

## Inline constants

`const` works in statement blocks too, with the same block scoping:

```pascal
begin
  const K = 50;                     // true compile-time constant, no storage
  const T: integer = 7;             // typed constant, block-scoped storage
  const A: array[3] of integer = (1, 2, 3);
  begin
    const inner = K*2;              // visible only in this block
  end;
end;
```

The plain `const K = expr` form needs a compile-time-evaluable expression and yields a true constant; the typed form `const K: T = v` follows the usual typed-constant rules (including `$J` writability) but is scoped to the declaring block.

## Where inline vars are valid

Wherever a statement is expected: top of a routine body, any nested `begin..end`, `if` / `while` / `repeat` body, `for` header, `with var` clause. **Not** valid in unit `interface` / `implementation` outside routines (use a `var` section for globals) or in class / record field declarations.

## Debugger support

Block-scoped inline vars emit proper DWARF: each `begin..end` containing inline vars gets a `DW_TAG_lexical_block` with address ranges, its variables are children of that entry, and for-loop inline vars get their own lexical block. The debugger shows only the variables visible at the current PC, and the Lazarus IDE scopes them in the Local Variables panel.

## Demo

```pascal
program inline_vars_demo;

{$mode unleashed}

function median(data: array of double): double;
begin
  // sort a local copy in place
  var a: array of double;
  SetLength(a, length(data));
  for var i := 0 to high(data) do a[i] := data[i];
  for var i := 0 to high(a)-1 do
    for var j := 0 to high(a)-1-i do
      if a[j] > a[j+1] then SwapValues(a[j], a[j+1]);
  var n := length(a);
  result := if odd(n) then a[n div 2] else (a[n div 2 - 1] + a[n div 2]) / 2;
end;

begin
  // inference: types come from the initializers
  var samples := [7.0, 2.0, 9.0, 4.0, 5.0]; // array of Double
  var label_ := 'median';                   // AnsiString
  writeln($'{label_} of {length(samples)} samples = {median(samples):4:1}');

  // block scope keeps a temporary from leaking
  var total := 0.0;
  begin
    var sq := 0.0;
    for var v in samples do sq += v*v;
    total := sq;
  end;
  writeln($'sum of squares = {total:6:1}');

  // a fresh accumulator on every pass
  for var run := 1 to 3 do begin
    var bucket: array of integer;
    for var k := 1 to run do bucket := bucket + [k];
    writeln($'run {run}: {length(bucket)} item(s)');
  end;
  {$ifdef WINDOWS}readln;{$endif}
end.
```

Output:

```
median of 5 samples =  5.0
sum of squares =  175.0
run 1: 1 item(s)
run 2: 2 item(s)
run 3: 3 item(s)
```
