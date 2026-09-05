# Out-Variables

Declare a variable inline at an `out`- or `var`-argument position, or discard the output, instead of pre-declaring a throwaway local for every output. `var x` at the argument binds the output to a fresh variable; `var x: T` gives it an explicit type; `var x := e` seeds it with an initial value; `_` throws it away.

```pascal
function TryParse(s: string; out value: integer): boolean; ...
procedure AddTo(var acc: integer; n: integer); ...

if TryParse('42', var n) then       // n declared here, type inferred
  writeln(n);                       // and stays in scope afterwards

AddTo(var total, 5);                // var parameter: total starts at 0
AddTo(var seeded := 100, 5);        // or at an explicit seed value

FillDWord(var raw: dword, 1, $FF);  // untyped parameter: the annotation supplies the type

GetCursorPos(_); // value not wanted: discard it
```

Modeswitch: `outvar`, enabled by default in `{$mode unleashed}`.

## `var x` - inline out-variable

At an `out` or `var` argument, `var name` declares a fresh variable whose type is taken from the matched parameter. The variable lands in the nearest enclosing block (the same scope an ordinary inline `var` would get) and is live from the call onward:

```pascal
procedure SplitName(full: string; out first, last: string); ...

SplitName('Ada Lovelace', var fn, var ln);
writeln(fn);                        // Ada
writeln(ln);                        // Lovelace
```

The type annotation is optional - a bare `var x` always infers the type from the parameter. The variable behaves like any local from then on: assignable, addressable, captured by closures, finalized at scope end.

`_` is a valid Pascal identifier, so `var _` is not special: it declares a variable literally named `_`, exactly as `var x` declares `x`.

## `var x: T` - explicit type

The declaration can name its type instead of inferring it. An annotated declaration binds only to a parameter of exactly the type `T` (type aliases count as the same type); an assignment-compatible but different type does not match. It combines with a seed: `var x: T := e`.

The annotation buys two things:

- **Untyped parameters.** `procedure grab(var buf)` has no type to infer from, so a bare `var x` is rejected there. The annotation supplies the type; the callee sees a fresh variable of exactly that size:

```pascal
procedure grab(var buf); ...

grab(var n: integer);        // fresh integer, zeroed, passed as the untyped argument
grab(var m: integer := 123); // same, starting at 123
```

- **Overload disambiguation.** A bare `var x` matches an `out`/`var` parameter of any type, which makes overloads differing only in that type ambiguous; the annotation pins the candidate (example below).

At a typed parameter the annotation is otherwise redundant: `AddTo(var x: integer, 5)` and `AddTo(var x, 5)` declare the same variable. Zero-init and seeds at `var` parameters work identically in both forms.

The annotation accepts any type a regular `var` declaration accepts, anonymous forms included (`var buf: array[0..3] of byte`). The discard `_` takes no annotation.

## `_` - discard

A bare `_` at an `out` or `var` argument throws the value away. The call still runs; the compiler passes a hidden local that nobody can name (zero-initialized when the parameter is `var`):

```pascal
// only the boolean result matters, not the position
if Pos2('x', s, _) then ...

// run the call for its side effects, drop the out value
GetState(_);
```

`_` is the same "don't care" marker unleashed already uses in tuple destructuring (`var (x, _, z) := t`) and match wildcards.

### A declared `_` always wins

`_` counts as a discard only when no identifier `_` is in scope. If one exists - a local, a field, a global from a used unit - `_` means that variable, everywhere, in every parameter position:

```pascal
var _: integer;
...
Fill(_);                            // writes into the variable _
writeln(_);                         // prints it
```

This keeps the feature backward compatible: code that declares `_` compiles and behaves identically with the modeswitch on or off. Note the flip side: with an `integer` variable `_` in scope, `_` at a `string` out parameter is now a type error, not a discard.

### No discard at intrinsics

`Write`, `Read`, `Str()`, `Val()` and the other compiler intrinsics have no regular parameter list to bind a type against, so `var x` / `_` are never recognized there. With no `_` declared it is simply an unknown identifier:

```pascal
writeln(_);                         // Error: Identifier not found "_"
Val(s, _, code);                    // Error: Identifier not found "_"
```

## `var` parameters: zero-init and seeds

A `var` parameter is an in/out parameter - the callee is free to read it before writing, so a fresh variable cannot simply be passed uninitialized. Instead the declaration gives it a defined value right before the call:

- `var x` initializes the variable to `Default(T)` - `0`, `0.0`, `false`, `nil`, `''`, zero-filled record/array - where `T` is the matched parameter's type.
- `var x := e` initializes it to `e` instead. The variable's type still comes from the parameter, not from the seed; the seed converts to it like an ordinary assignment (`AddTo(var d := 1, 0.5)` seeds a `double` parameter with `1.0`).

```pascal
procedure AddTo(var acc: integer; n: integer);
begin
  acc := acc + n;
end;

AddTo(var total, 5);        // total = 0, then +5 -> 5
AddTo(var sub := 100, 5);   // sub = 100, then +5 -> 105
```

The initialization runs per call, not once per scope. Inside a loop, every iteration re-zeroes (or re-seeds) the variable before the call:

```pascal
for var i := 1 to 3 do begin
  AddTo(var c, 5);          // c re-zeroed each pass: 5 after every call, not 5, 10, 15
  ...
end;
```

A discarded `_` at a `var` parameter passes a zero-initialized hidden temp, so the callee never observes garbage.

Two kinds of locals keep their normal initialization instead of a zero fill: file types (`Text`, `file`, `file of T`), whose proper closed state is set up by the RTL and is not all-zeros, and records, arrays, and objects with a file field nested anywhere inside them. Both still declare and bind fine; they are only not zeroed.

The seed exists for `var` parameters only. At an `out` parameter it would be discarded unread, so a seeded declaration is rejected with `A seed value is not allowed at an "out" parameter, the callee never reads it`. The declared name is not yet in scope inside the seed: `var q := q + 1` reads an existing outer `q` when there is one (the new `q` shadows it only after the declaration), and is an unknown identifier otherwise.

## Where it is allowed

`var x` / `_` are accepted at an **`out`** or **`var`** parameter. At `const` and value parameters the placeholder does not match, so the call fails overload matching:

```pascal
procedure byConst(const x: integer);

byConst(var y); // rejected - an input, not an output
```

An **untyped** `var` or `out` parameter accepts only an annotated declaration - a bare `var x` has no type to infer, and the discard's hidden temp has none to take:

```pascal
procedure grab(var buf);

grab(var y);          // Error: Cannot infer a type from an untyped parameter, use an explicit type: "var x: type"
grab(_);              // Error: Cannot discard at an untyped parameter, there is no type for the hidden variable
grab(var y: integer); // OK - the annotation supplies the type
```

An **open array** parameter (`array of T`) only views an array the caller already has; it cannot grow. A bare `var y` bound to one becomes an empty dynamic array of the element type, `TArray<T>`, and the compiler warns that the callee cannot fill it. After the call `y` is a normal dynamic array (`length(y) = 0`). The discard `_` passes an empty array without a warning, since discarding is deliberate:

```pascal
procedure scan(out q: array of string);

scan(var y);         // Warning: Out-variable bound to an open array parameter is empty, the callee cannot resize it; declare the parameter as TArray<T> or pass an existing array
writeln(length(y));  // 0
scan(_);             // OK, silent: the callee sees an empty array
```

To let the callee return a new array, declare the parameter as `TArray<T>` (or another dynamic array type); a `var y` bound to it then receives whatever the callee allocates.

## Type inference happens after overload resolution

`var x` / `_` carry no type until a candidate is chosen, so they match an `out` or `var` parameter of *any* type. If overloads differ only in that parameter's type - or only in `out` vs `var` - the call is ambiguous:

```pascal
procedure Take(out x: integer); overload;
procedure Take(out x: string); overload;

Take(var y); // Error: Can't determine which overloaded function to call
```

Pin it down through another argument, or do not overload on the out type alone. A seeded declaration prefers `var` parameters, so it also disambiguates an `out`/`var` overload pair:

```pascal
procedure Pick(out x: integer); overload;
procedure Pick(var x: string); overload;

Pick(var z);          // ambiguous - matches both
Pick(var z := 'hi');  // picks the var overload
```

An annotated declaration matches only its own type, so it resolves overloads that differ in the parameter type:

```pascal
Take(var y: integer); // picks the integer overload
```

## Name collision

`var name` is a real declaration, so a name already visible in scope is a duplicate:

```pascal
var offset: integer;
...
Find(s, sub, var offset); // Error: Duplicate identifier "offset"
```

Drop the `var` to pass the existing variable (`Find(s, sub, offset)`), or pick a fresh name.

## Managed types

Captured and discarded out-variables of a managed type (string, dynamic array, interface, `Variant`) are ordinary locals: initialized on entry, finalized at scope end through the normal mechanism. Discards in a loop finalize per iteration - no leaks:

```pascal
procedure Build(out s: string); ...

Build(var text);                    // text finalized at scope end
for i := 1 to n do
  Build(_);                         // hidden temp finalized each pass
```

## Scope

The variable is added to the nearest enclosing block: a routine body, a nested `begin..end`, or the program main block. Like an inline `var`, it lives to the end of that block, not just the one statement:

```pascal
procedure run;
begin
  if lookup(key, var found) then use(found);
  writeln(found); // still in scope here
end;
```

## How it works

The parser turns `var x` / `_` into a load of a placeholder local (created with the annotated type, or with an error type when bare, inserted only after the seed is parsed) and flags the call argument; a `:=` seed expression is kept alongside. Overload matching treats a bare flagged argument as an exact match for an `out` or `var` parameter of any type, and an annotated one for a parameter of equal type or an untyped one; a seeded declaration ranks `out` below any `var` match. Once a candidate wins, binding sets a bare placeholder's type to the chosen parameter's type and re-checks the load; a seed that ended up at an `out` parameter is rejected there, and for a `var` parameter binding emits an assignment of the seed - or `Default(T)` - into the call's init block, executed immediately before the call. The flag is cleared at that point, so it never reaches code generation or a PPU.

## Want it off?

```pascal
{$mode unleashed}
{$modeswitch outvar-}

GetCursorPos(var p); // no longer recognized - syntax error
```

Outside unleashed (or with the switch off) `var` / `_` at an argument are not recognized, so existing code is never affected - the feature is purely opt-in.

## Demo

```pascal
program out_var_demo;

{$mode unleashed}

uses SysUtils;

procedure splitAt(const s: string; sep: char; out head, tail: string);
begin
  var p := Pos(sep, s);
  if p = 0 then begin
    head := s;
    tail := '';
  end else begin
    head := Copy(s, 1, p-1);
    tail := Copy(s, p+1, Length(s));
  end;
end;

procedure addTo(var acc: integer; n: integer);
begin
  acc := acc + n;
end;

begin
  // declare receivers right at the call
  splitAt('width=1920', '=', var key, var value);
  if TryStrToInt(value, var w) then writeln($'{key} -> {w} (as integer)');

  // only care whether it parses - discard the value
  if TryStrToInt('oops', _) then writeln('parsed') else writeln('not a number');

  // var parameter: a fresh accumulator starts at 0...
  addTo(var sum, w);
  // ...or at an explicit seed
  addTo(var padded := 80, w);
  writeln($'sum={sum} padded={padded}');
  {$ifdef WINDOWS}readln;{$endif}
end.
```

Output:

```
width -> 1920 (as integer)
not a number
sum=1920 padded=2000
```
