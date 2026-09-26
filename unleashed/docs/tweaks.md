# Tweaks

Small semantic adjustments that make standard Pascal constructs behave the way most people expect them to. Most of them have no dedicated modeswitch - they are unleashed-mode-only and turn on with `{$mode unleashed}` (or `-Munleashed`). The `is not` / `not in` operators are the exception: they sit behind the `reorderedoperators` modeswitch, which `unleashed` and `delphi` modes turn on by default.

If you need the standard semantics for a specific routine, switch the mode locally back to `objfpc` / `delphi`.

## Preserved for-loop counter

In standard Pascal the value of the for-loop counter after the loop exits is *undefined*. Delphi documents it explicitly and FPC follows the same rule - the optimizer is allowed to leave any value behind, and the generated code typically overshoots the final bound because that makes the exit comparison cheaper.

That bites every time you write:

```pascal
for i := 1 to n do
  if x[i] = target then break;
if i <= n then writeln('found at ', i); // works only by accident on stock FPC
```

### What unleashed mode does

The counter is guaranteed to keep its last assigned value across the exit:

| Exit path | Value of `i` after the loop |
|---|---|
| Natural end (`for i := 1 to 10 do ;`) | `10` (last in-range value) |
| `break` somewhere in the body | the value at break time |
| `continue` through to the natural end | last in-range value |
| Single-iteration range (`for i := 5 to 5 do ;`) | `5` |
| Empty range (`for i := 10 to 1 do ;`) | unchanged (body never runs, counter never assigned) |
| `downto` natural exit (`for i := 10 downto 1 do ;`) | `1` (the lower bound) |
| `downto` with break | the value at break time |

Nested loops preserve each counter independently:

```pascal
for i := 1 to 3 do
  for j := 100 to 105 do ;
writeln(i, ' ', j); // 3 105
```

### Interaction with `step`

A loop with a `step` clause is lowered to a while loop that advances the counter and then tests it, so on the natural exit the counter holds the **first value past the bound**, not the last one the body saw. `break` still keeps the exact break-time value:

```pascal
for i := 1 to 10 step 4 do ;               // body sees 1, 5, 9
writeln(i);                                // 13 (9 + step, first out-of-range value)

for i := 20 downto 1 step 3 do ;           // body sees 20, 17, ..., 2
writeln(i);                                // -1 (2 - step)

for i := 1 to 10 step 4 do
  if i = 5 then break;
writeln(i); // 5 (break-time value, exact)
```

"Last assigned value" is still the guarantee - with `step` the last assignment is the advance that terminated the loop. When the post-loop value matters, prefer `break` (exact) or derive the last body value as `i - step` / `i + step` after a natural exit. See [forstep.md](forstep.md) for the `step` clause itself.

### Why standard Pascal does not do this

Stock FPC sets the `lnf_dont_mind_loopvar_on_exit` flag on every for-loop in `fpc` / `objfpc` / `delphi` mode. The flag tells the code generator the counter is dead after the loop, which lets it pick whichever exit-condition encoding is cheapest - typically leaving the counter *one past* the last in-range value (`for i := 1 to 10` leaves `i = 11`, not `10`). In `mac` / `tp` mode the flag is not set, because both languages historically defined the counter as preserved.

### What unleashed actually changes

Just the parser hook: it stops setting `lnf_dont_mind_loopvar_on_exit` when `m_unleashed` is active. The regular code generator path then keeps the counter at its last assigned value. Cost: one extra assignment on the natural exit path; nothing on `break`, `continue`, or `exit`.

### Want the standard "undefined on exit" semantics back?

Switch the mode for the affected code:

```pascal
{$mode objfpc}

procedure hotLoop;
begin
  // i is undefined after the loop here - standard FPC semantics
end;
```

## `is not` and `not in` operators

> [!NOTE]
> Available in FPC mainstream since 2026-09-23

Standard Pascal forces an extra pair of parentheses on negated type checks and membership tests:

```pascal
if not (obj is TFoo) then ...
if not (x in [apple, orange]) then ...
```

With the `reorderedoperators` modeswitch the compiler accepts the form you say out loud. The switch is on by default in `{$mode unleashed}` and `{$mode delphi}`; any other mode gets it with `{$modeswitch reorderedoperators}`:

```pascal
if obj is not TFoo then ...
if x not in [apple, orange] then ...
```

Each compiles to exactly the same node tree as the parenthesized form - semantics, error messages, and runtime cost are unchanged.

### What the modeswitch actually changes

Just the parser. When the comparison-level expression sees `is` followed by `not`, it consumes both and wraps the resulting `is` node in a `not` node. The `not in` form is allowed at the comparison level (where `not` is normally a unary prefix only) and parses the right-hand side as the operand of `in`.

Without the modeswitch the parser rejects both: `obj is not T` is read as `obj is (not T)` and reports an operator error (`Operator is not overloaded: not "Class Of T"`), and `x not in S` is a syntax error at `not`.

## Default-on switches

Three module-level switches that are off by default in `fpc` / `objfpc` are turned on automatically by `{$mode unleashed}`, so the constructs they gate work out of the box:

| Switch | Directive / flag | What it enables |
|---|---|---|
| goto support | `{$goto on}` / `-Sg` | `label` declarations and `goto` (see also [indexed-labels.md](indexed-labels.md)) |
| C-style operators | `{$coperators on}` / `-Sc` | `+=`, `-=`, `*=`, `/=` (see [compound-assignment.md](compound-assignment.md)) |
| macros | `{$macro on}` / `-Sm` | text-substitution macros (`$define name := value`) |

(`inline` support is on too, but that comes from the `objfpc` base mode, not an unleashed addition.)

Each can be switched back off locally with the `off` form of its directive, e.g. `{$goto off}`.

### What unleashed actually changes

The mode handler includes `cs_support_goto`, `cs_support_c_operators`, and `cs_support_macro` in the module switches whenever `m_unleashed` is set, mirroring how `delphi` / `tp7` / `mac` already default goto on.

## Future tweaks

This page is the catalog for small unleashed-only semantic adjustments. As more of them land, they get appended here with the same shape: what the standard does, what unleashed changes, and how to opt back into the standard when you need it.

## Demo

```pascal
program tweaks_demo;

{$mode unleashed}

{$define GREETING := 'macros work out of the box'}

type
  TFruit = (fApple, fOrange, fPlum);
  TShape = class end;
  TCircle = class(TShape) end;

begin
  // preserved for-loop counter: find first multiple of 7
  var nums := [12, 91, 35, 98, 77];
  var i: integer;
  for i := 0 to high(nums) do
    if nums[i] mod 7 = 0 then break;
  writeln('first multiple of 7 at index ', i, ' (value ', nums[i], ')');

  for i := 1 to 10 do ;
  writeln('after natural exit: i = ', i);

  // is not / not in
  var shape: TShape := TShape.Create;
  if shape is not TCircle then writeln('not a circle');
  var basket: set of TFruit := [fApple, fPlum];
  if fOrange not in basket then writeln('no orange in basket');
  shape.Free;

  writeln(GREETING);
  {$ifdef WINDOWS}readln;{$endif}
end.
```

Output:

```
first multiple of 7 at index 1 (value 91)
after natural exit: i = 10
not a circle
no orange in basket
macros work out of the box
```
