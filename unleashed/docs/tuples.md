# Anonymous Tuples

Tuples are lightweight anonymous record types written in parentheses, with literals, destructuring, comparison, and full record semantics. Use them instead of `out`-parameter pairs and one-shot record types declared only to return two values. A tuple is stored as an ordinary internal record, so everything the record infrastructure already does (field access, per-field assignment, copy semantics, managed-type init / fini, passing by value / var / const) works unchanged.

Modeswitch: `tuples`, enabled by default in `{$mode unleashed}`.

## Declaring tuple types

### Positional (auto-named `_1`, `_2`, ...)

```pascal
function getPair: (integer, integer);
var p: (integer, string);
```

Fields get canonical names `_1`, `_2`, ..., accessible by name or by constant integer index (0-based):

```pascal
p._1 := 10;                 // by name
p._2 := 'hello';
writeln(p[0], ' ', p[1]);   // by index - same as _1, _2
```

The index must be a compile-time constant - a variable index is impossible because field types can differ (`(integer, string)`), so `t[i]` for a runtime `i` has no single result type.

### Named (user-chosen field names)

Names on the left, `:`, then the type. Names share a type via comma; type groups are separated by `;`, as in record fields:

```pascal
function coords: (a, b: integer);
function row: (x: integer; y: string);
function mixed: (a, b: integer; s: string; f: double);
```

## Tuple literals

```pascal
// positional
result := (10, 20);
p := (42, 'hello');

// named (any order, each field set exactly once)
result := (a: 10, b: 20);
result := (b: 20, a: 10);
```

## `exit` sugar

Inside a function with a tuple return type, `exit` takes a literal directly:

```pascal
function foo: (integer, integer);
begin
  if cond then exit(10, 20); // positional
  result := (100, 200);
end;

function bar: (a, b: integer);
begin
  exit(a: 1, b: 2); // named
end;
```

## Destructuring

```pascal
// inline var destructuring - binds by POSITION, names may differ from the fields
var (x, y) := getPair;
var (num, text) := getMix;

// multi-assignment to existing variables
var x, y: integer;
(x, y) := getPair;

// swap idiom
(x, y) := (y, x);

// targets are any assignable expressions: array elements, fields, derefs
(a[0], a[1]) := (a[1], a[0]);
(r.p, r.q) := getPair;

// wildcard _ ignores a field
var (first, _, _, last) := getQuad;
```

## Function parameters

```pascal
// tuple parameter type
procedure show(p: (integer, integer));

// destructured parameter - name the fields directly
procedure process((x, y): (integer, integer));

// inline named-tuple shorthand (equivalent to the explicit form above)
procedure bar((x, y: integer; name: string));
```

## Comparison

```pascal
if (1, 2) = (1, 2) then ...;   // field-by-field equality
if (1, 2) < (1, 5) then ...;   // lexicographic ordering
```

Tuples of different shapes: `=` returns false and `<>` returns true (no error), but the ordering operators (`<`, `>`, `<=`, `>=`) between different shapes are a compile error (`Tuples have different shapes and cannot be compared`).

## `writeln()`

```pascal
var t := (42, 'hello');
writeln(t); // 42, hello
```

## for-in destructuring

```pascal
for var (key, value) in dict do
  writeln(key, '=', value);

for var (key, _) in pairs do // wildcard works here too
  writeln(key);
```

## Tuples as array elements

```pascal
var pairs: array of (integer, integer);
pairs := [(1, 2), (3, 4), (5, 6)];
```

Tuple literals inside an array literal build the declared element type automatically; sub-32-bit integer literals and constant strings promote to `Int32` / the mode's default string type to match the typical declarations.

## Nested tuples

```pascal
var n: (integer, (string, integer));
n := (5, ('label', 42));
writeln(n._2._1); // label
```

## Tuples as record fields

```pascal
type
  TItem = record
    id: integer;
    pt: (x, y: integer);
  end;
```

## Structural compatibility

Two tuples of matching shape (same field count, same types in order) are compatible. If either side is positional, field names are not checked - so a positional literal `(10, 20)` assigns to a named tuple `(a, b: integer)` of the same shape. Two named tuples with different names stay distinct. Tuples are also structurally compatible with regular records of the same shape when either side carries the tuple flag.

## Generics

```pascal
function makePair<A, B>(x: A; y: B): (A, B);
function zip<A, B>(const xs: array of A; const ys: array of B): array of (A, B);
```

A tuple type is also accepted directly as a specialization argument, no alias needed:

```pascal
function make(out q: TArray<(a: integer; b: string)>): boolean;
procedure show(const items: TArray<(a: integer; b: string)>);

var stored: TArray<(a: integer; b: string)>;
```

The same shape written in two places (two declarations, two routines, two units) names the same specialization: `stored := t` works, and so does passing `stored` to a `var` or `out` parameter declared with that type. A positional `TArray<(integer, integer)>` and a named `TArray<(a, b: integer)>` are separate specializations that stay assignment compatible, like the tuples themselves; two named tuples with different field names are distinct types.

This works in every type position: parameters of any kind, result types, `var` sections, inline `var`, record fields, `type` aliases, inline specializations in expressions (`TBox<(a: integer; b: string)>.Create`, `makePair<(integer, string), integer>(...)`), and it nests: `TArray<TArray<(integer, string)>>`, `TArray<array of (a: integer; b: string)>`.

Other anonymous types are accepted the same way in unleashed mode: `array of T`, `array[N] of T`, `set of T`, `^T` and `record ... end`. Arrays, sets and pointers are matched by shape like tuples; an anonymous `record` is a new type each time, as in a type declaration.

## Typed constants

```pascal
const
  origin: (integer, integer) = (0, 0);           // positional
  point:  (x, y: integer)    = (10, 20);         // named type, positional literal
  named:  (x, y: integer)    = (x: 10, y: 20);   // named type, named literal
  classic: (integer, integer) = (_1: 0; _2: 0);  // record-style also works
```

## Not supported

- **One-element tuples** - `(42)` is an arithmetic expression, not a tuple.
- **`case` on a tuple** - a tuple is not an ordinal / string, so `case t of (1, 2): ...` reports `Ordinal or string expression expected`. Use [`match`](match.md) with tuple patterns instead.
- **Full RTTI / TypeInfo** for tuple types.

## Demo

```pascal
program tuple_demo;

{$mode unleashed}

// two return values without an out-pair or a throwaway record type
function minMax(const a: array of integer): (lo, hi: integer);
begin
  result := (a[0], a[0]);
  for var v in a do begin
    if v < result.lo then result.lo := v;
    if v > result.hi then result.hi := v;
  end;
end;

function divMod(a, b: integer): (integer, integer);
begin
  exit(a div b, a mod b);
end;

var grid: array of (integer, integer);
begin
  var (lo, hi) := minMax([34, 7, 23, 62, 5]); // destructuring
  writeln($'min={lo} max={hi}');

  var (q, r) := divMod(17, 5);
  writeln($'17 = {q}*5 + {r}');

  var x := 1; var y := 2;
  (x, y) := (y, x); // swap
  writeln($'swapped: {x} {y}');

  grid := [(1, 2), (3, 4), (5, 6)];
  for var (a, b) in grid do write($'({a},{b}) ');
  writeln;
  {$ifdef WINDOWS}readln;{$endif}
end.
```

Output:

```
min=5 max=62
17 = 3*5 + 2
swapped: 2 1
(1,2) (3,4) (5,6)
```
